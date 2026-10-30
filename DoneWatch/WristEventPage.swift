//
//  WristEventPage.swift
//  DoneWatch
//
//  The page left of Today: one event — the block selected on Today, else
//  the running session, else a line saying to tap one (`WristEventSubject`).
//  Its end, large, is what the Digital Crown moves while this page is the
//  one showing (`WristEndCrown`); the change goes to the phone once the
//  crown rests, or at once when the page is left. The running session also
//  gets +15 and Finish (the double tap).
//

import SwiftUI
import WatchKit

/// Today's selected range, shared by Today (which sets it) and the event
/// page (whose subject it is) — observed by those two alone, so a tap
/// redraws them and not the root with every page.
@MainActor
final class WristSelectionModel: ObservableObject {
    @Published var selection: WristEventSubject.Selection?
}

struct WristEventPage: View {
    @ObservedObject var selectionModel: WristSelectionModel
    /// Today's blocks as the day lays them out, the running session, and
    /// what the crown may do with them.
    let blocks: [WristDayBlock]
    let running: WristOccurrence?
    let takesRangeEdits: Bool
    let dayStart: Date
    let dayEnd: Date
    /// Blocks this watch created that the phone has not reflected yet.
    let localCreates: Set<UUID>
    /// The events with a command the phone has not answered.
    let pendingEventIDs: Set<UUID>
    /// The page showing — this one, or another: only while it is this
    /// one is the crown its. A binding, read here: the minute schedule's
    /// content does not re-run when the page turns, so a plain value
    /// passed down would go stale.
    @Binding var page: WristPage
    private var isVisible: Bool { page == .event }
    let now: Date
    let strings: WristStrings
    let onSend: (WristEndCrownSession.Send) -> Void
    let onExtend: (WristOccurrence) -> Void
    let onFinish: (WristOccurrence) -> Void

    @State private var session = WristEndCrownSession()
    @State private var restToken = UUID()
    /// The crown is turning: the end shown is where it is going.
    @State private var turning = false
    @Environment(\.scenePhase) private var scenePhase

    private var subject: WristEventSubject? {
        WristEventSubject.resolve(selection: selectionModel.selection, blocks: blocks, running: running)
    }

    private var availability: WristEndCrown.Availability? {
        subject.map {
            WristEndCrown.availability(
                for: $0, blocks: blocks, takesRangeEdits: takesRangeEdits,
                dayStart: dayStart, dayEnd: dayEnd, now: now, localCreates: localCreates
            )
        }
    }

    private struct Input: Equatable {
        var subject: WristEventSubject?
        var availability: WristEndCrown.Availability?
    }

    var body: some View {
        let subject = subject
        let availability = availability
        WristPageFrame(header: nil) { top in
            Group {
                if let subject {
                    content(subject, availability: availability)
                } else {
                    Text(strings.eventPageEmpty)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(.top, top + 2)
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
        // The crown's host, a leaf of its own: its rotation changes every
        // frame of a turn, and only whole detents reach the page.
        .background {
            WristCrownDetents(isActive: isVisible) { delta, raw in turnEnd(delta, raw: raw) }
        }
        .onAppear {
            show(Input(subject: subject, availability: availability))
        }
        // Paged away, the page is taken down before the selection says so:
        // what was turned goes now, and the crown is the day's again.
        .onDisappear {
            WristGestureTrail.note("event page gone — crown back to the day")
            leave()
        }
        .onChange(of: Input(subject: subject, availability: availability)) { _, new in show(new) }
        .onChange(of: pendingEventIDs) { _, ids in session.settle(pendingEventIDs: ids) }
        // The wrist going down mid-turn sends it, as leaving does; back up
        // on this page, the crown is its again.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { leave() }
        }
        // The crown is this page's only while it shows: leaving sends what
        // was turned, and the crown host lets the crown go back to the day.
        .onChange(of: isVisible) { _, visible in
            WristGestureTrail.note("event page \(visible ? "shown — crown moves the end" : "left — crown back to the day")")
            if !visible { leave() }
        }
    }

    private func leave() {
        restToken = UUID()
        turning = false
        sendUnsent()
    }

    private func show(_ input: Input) {
        if session.show(input.subject, availability: input.availability) {
            WristGestureTrail.note("event page: subject changed mid-turn — unsent turn dropped")
        }
    }

    /// Whole detents of the crown (in its sign), or one VoiceOver
    /// adjustment: stops of the end, sent once the turning rests.
    private func turnEnd(_ delta: Int, raw: Double?) {
        guard isVisible, let step = session.turn(crownDelta: delta) else { return }
        let target = session.shownEnd ?? Date()
        WristGestureTrail.note(String(
            format: "crown raw=%@ step=%d → end %@%@",
            raw.map { String(format: "%.2f", $0) } ?? "voiceover", delta, strings.clock(target),
            step.limited && !step.moved ? " limit" : ""
        ))
        if step.moved {
            WKInterfaceDevice.current().play(.click)
        } else if step.limited {
            WKInterfaceDevice.current().play(WristEndCrown.direction(ofCrownDelta: delta) > 0 ? .directionUp : .directionDown)
        }
        turning = true
        let token = UUID()
        restToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + WristEndCrown.restDelay) {
            guard restToken == token else { return }
            turning = false
            sendUnsent()
        }
    }

    private func sendUnsent() {
        guard let send = session.takeUnsent(now: Date()) else { return }
        WristGestureTrail.note("event page: send \(send.occurrence.title) \(strings.timeRange(send.start, send.end))")
        onSend(send)
    }

    @ViewBuilder
    private func content(_ subject: WristEventSubject, availability: WristEndCrown.Availability?) -> some View {
        let occurrence = subject.occurrence
        let accent = WristColor.color(occurrence.colorHex)
        let crown = session.range == subject.selection ? session.crown : nil
        let end = crown?.target ?? occurrence.end
        let changed = crown?.hasUnsent ?? false
        let sending = pendingEventIDs.contains(occurrence.eventID) || (crown?.inFlight ?? false)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 1.5).fill(accent).frame(width: 3, height: 14)
                (Text(occurrence.title).foregroundStyle(.white)
                    + Text(occurrence.title == occurrence.type ? "" : " · \(occurrence.type)").foregroundStyle(.secondary))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if occurrence.isOpenEnded {
                Text(strings.running)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(strings.durationFrom(occurrence.start, max(now, occurrence.start)))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Text(strings.clock(end))
                    .font(.system(size: 46, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(changed || turning ? accent : .white)
                    .contentTransition(.numericText(value: end.timeIntervalSinceReferenceDate))
                    .animation(.easeOut(duration: 0.12), value: end)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    // VoiceOver moves the end a stop a swipe, as a detent.
                    .accessibilityLabel(strings.endLabel)
                    .accessibilityValue(strings.clock(end))
                    .accessibilityAdjustableAction { direction in
                        let sign = direction == .increment ? 1 : direction == .decrement ? -1 : 0
                        guard sign != 0 else { return }
                        turnEnd(sign * WristEndCrown.crownLater, raw: nil)
                    }
                Text(strings.durationFrom(occurrence.start, end))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Group {
                if sending, !turning {
                    Text(strings.sending)
                } else if case .refused(let refusal) = availability {
                    Text(refusal == .phoneTooOld ? strings.updatePhoneForEdits : strings.editOnPhoneShort)
                } else {
                    Text(" ")
                }
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 2)
            Spacer(minLength: 0)
            if subject.isRunning, occurrence.quickActionsEnabled {
                HStack(spacing: 6) {
                    Button {
                        restToken = UUID()
                        turning = false
                        sendUnsent()
                        onExtend(occurrence)
                    } label: {
                        Text(strings.extend)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(Color.white.opacity(0.18), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Button {
                        restToken = UUID()
                        turning = false
                        session.discardUnsent()
                        onFinish(occurrence)
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 15, weight: .bold))
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(accent.opacity(0.85), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(strings.finish)
                    // The double tap finishes only from this page: it stays
                    // loaded beside Today, whose double tap is not Finish.
                    .handGestureShortcut(.primaryAction, isEnabled: isVisible)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

}

/// The crown while the event page shows: an invisible view that takes the
/// crown's focus and reports whole detents — `delta` in the rotation's own
/// sign (`WristEndCrown.crownLater` says which is later). Its rotation
/// changes every frame of a turn; only this leaf redraws for it. Not
/// active, it is not focusable, and the crown is the day's.
struct WristCrownDetents: View {
    let isActive: Bool
    let onDetents: (_ delta: Int, _ raw: Double) -> Void

    @State private var turned = 0.0
    @State private var detents = 0
    @FocusState private var focused: Bool
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Color.clear
            .focusable(isActive)
            .focused($focused)
            .focusEffectDisabled()
            .digitalCrownRotation(
                $turned, from: -100_000, through: 100_000, by: 1,
                sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: false
            )
            .accessibilityHidden(true)
            .onChange(of: turned) { _, raw in
                let now = Int(raw.rounded())
                let delta = now - detents
                guard delta != 0 else { return }
                detents = now
                onDetents(delta, raw)
            }
            .onChange(of: focused) { _, focused in
                WristGestureTrail.note("event page crown focus \(focused ? "taken" : "let go") active=\(isActive)")
            }
            .onAppear {
                if isActive { takeFocus() }
#if DEBUG
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { seedDebugTurn() }
#endif
            }
            .onChange(of: isActive) { _, active in
                if active { takeFocus() } else { focused = false }
            }
            // Back from the wrist going down on this page: the crown is
            // its again. Asked once per return, never in a loop.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active, isActive { takeFocus() }
            }
    }

    private func takeFocus() {
        DispatchQueue.main.async {
            guard isActive else { return }
            focused = true
        }
    }

#if DEBUG
    /// `-wristCrownSteps <n>` turns the crown n detents (positive = the
    /// turn that scrolls Today later) once the page is showing, through the
    /// same path a real detent takes, so a simulator that cannot turn the
    /// crown can still check the stops and the single send at rest. Debug
    /// builds only.
    private func seedDebugTurn() {
        let arguments = ProcessInfo.processInfo.arguments
        guard isActive, let i = arguments.firstIndex(of: "-wristCrownSteps"), i + 1 < arguments.count,
              let steps = Int(arguments[i + 1]), steps != 0 else { return }
        // One detent at a time, as a slow turn would, faster than the rest
        // delay: one send at the end.
        for n in 1...abs(steps) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15 * Double(n)) {
                turned += Double(steps.signum() * WristEndCrown.crownLater)
            }
        }
    }
#endif
}
