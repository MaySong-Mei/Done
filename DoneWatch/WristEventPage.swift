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

struct WristEventPage: View {
    let subject: WristEventSubject?
    let availability: WristEndCrown.Availability?
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
    /// The crown's raw value and the detents counted from it.
    @State private var turned = 0.0
    @State private var detents = 0
    @State private var restToken = UUID()
    /// The crown is turning: the end shown is where it is going.
    @State private var turning = false
    @FocusState private var focused: Bool
    @Environment(\.scenePhase) private var scenePhase

    private struct Input: Equatable {
        var subject: WristEventSubject?
        var availability: WristEndCrown.Availability?
    }

    var body: some View {
        WristPageFrame(header: nil) { top in
            Group {
                if let subject {
                    content(subject)
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
        // The crown's host: an invisible view behind the page that takes
        // the crown's focus while the page shows.
        .background {
            Color.clear
                .focusable(isVisible)
                .focused($focused)
                .focusEffectDisabled()
                .digitalCrownRotation(
                    $turned, from: -100_000, through: 100_000, by: 1,
                    sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: false
                )
                .accessibilityHidden(true)
        }
        .onChange(of: turned) { _, raw in crown(raw) }
        .onChange(of: focused) { _, focused in
            WristGestureTrail.note("event page crown focus \(focused ? "taken" : "let go") visible=\(isVisible)")
        }
        .onAppear {
            show(Input(subject: subject, availability: availability))
            if isVisible { takeFocus() }
#if DEBUG
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { seedDebugTurn() }
#endif
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
            if phase == .active {
                if isVisible { takeFocus() }
            } else {
                restToken = UUID()
                turning = false
                sendUnsent()
            }
        }
        // The crown is this page's only while it shows: leaving sends what
        // was turned and lets the crown go back to Today's day.
        .onChange(of: isVisible) { _, visible in
            WristGestureTrail.note("event page \(visible ? "shown — crown moves the end" : "left — crown back to the day")")
            if visible {
                takeFocus()
            } else {
                leave()
            }
        }
    }

    private func leave() {
        focused = false
        restToken = UUID()
        turning = false
        sendUnsent()
    }

    private func takeFocus() {
        DispatchQueue.main.async {
            guard isVisible else { return }
            focused = true
        }
    }

    private func show(_ input: Input) {
        if session.show(input.subject, availability: input.availability) {
            WristGestureTrail.note("event page: subject changed mid-turn — unsent turn dropped")
        }
    }

    private func crown(_ raw: Double) {
        let now = Int(raw.rounded())
        let delta = now - detents
        guard delta != 0 else { return }
        detents = now
        guard isVisible, let step = session.turn(crownDelta: delta) else { return }
        let target = session.shownEnd ?? Date()
        WristGestureTrail.note(String(
            format: "crown raw=%.2f detent=%d step=%d → end %@%@",
            raw, now, delta, strings.clock(target), step.limited && !step.moved ? " limit" : ""
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
    private func content(_ subject: WristEventSubject) -> some View {
        let occurrence = subject.occurrence
        let accent = WristColor.color(occurrence.colorHex)
        let crown = session.key == subject.key ? session.crown : nil
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
                    .handGestureShortcut(.primaryAction)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

#if DEBUG
    /// `-wristCrownSteps <n>` turns the crown n detents (positive = the
    /// turn that scrolls Today later) once the page is showing, through the
    /// same path a real detent takes, so a simulator that cannot turn the
    /// crown can still check the stops and the single send at rest. Debug
    /// builds only.
    private func seedDebugTurn() {
        let arguments = ProcessInfo.processInfo.arguments
        guard isVisible, let i = arguments.firstIndex(of: "-wristCrownSteps"), i + 1 < arguments.count,
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
