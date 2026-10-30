//
//  WristEventPage.swift
//  DoneWatch
//
//  The page left of Today: one event — the block selected on Today, else
//  the running session, else a line saying to tap one (`WristEventSubject`).
//  A plain scroll view the crown scrolls: on top the event and its end,
//  large; scrolled down, − and +, each a stop of the end (`WristEndCrown`:
//  the grid, neighbours' edges, what the phone keeps, the shortest, the
//  day's end). The taps go to the phone together a moment after the last,
//  or at once when the page is left.
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
    /// what the end may do among them.
    let blocks: [WristDayBlock]
    let running: WristOccurrence?
    let takesRangeEdits: Bool
    let dayStart: Date
    let dayEnd: Date
    /// Blocks this watch created that the phone has not reflected yet.
    let localCreates: Set<UUID>
    /// The events with a command the phone has not answered.
    let pendingEventIDs: Set<UUID>
    /// The page showing — this one, or another. A binding, read here: the
    /// minute schedule's content does not re-run when the page turns, so a
    /// plain value passed down would go stale.
    @Binding var page: WristPage
    private var isVisible: Bool { page == .event }
    let now: Date
    let strings: WristStrings
    let onSend: (WristEndCrownSession.Send) -> Void

    @State private var session = WristEndCrownSession()
    @State private var restToken = UUID()
    /// Taps not yet sent: the end shown is where they go.
    @State private var stepping = false
    /// The last stop went earlier: the digits roll down.
    @State private var countsDown = false
    @Environment(\.scenePhase) private var scenePhase
    /// The crown scrolls this page's scroll view while it shows. Turned to
    /// by a flick from Today (set in code), the paged view leaves the crown
    /// with Today's: it is asked for here, once per showing.
    @FocusState private var scrollFocused: Bool

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

    /// The − and + row, and the room under it.
    static let buttonHeight: CGFloat = 46
    static let buttonGap: CGFloat = 8

    var body: some View {
        let subject = subject
        let availability = availability
        WristPageFrame(header: nil) { top in
            if let subject {
                GeometryReader { screen in
                    ScrollView {
                        VStack(spacing: 0) {
                            info(subject, availability: availability)
                                .padding(.top, top + 2)
                                .padding(.horizontal, 10)
                                // The event fills the screen: at rest the
                                // buttons wait below it.
                                .frame(height: screen.size.height, alignment: .top)
                            if case .moves = availability {
                                buttons(subject)
                                    .padding(.horizontal, 8)
                                    .padding(.top, Self.buttonGap)
                                    // Clear of the page dots.
                                    .padding(.bottom, Self.buttonGap + 12)
                            }
                        }
                    }
                    .scrollTargetBehavior(WristTwoRestScroll())
                    .scrollIndicators(.hidden)
                    .focused($scrollFocused)
                    .defaultScrollAnchor(Self.opensRevealed ? .bottom : .top)
                }
            } else {
                Text(strings.eventPageEmpty)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            show(Input(subject: subject, availability: availability))
            takeCrown()
#if DEBUG
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { seedDebugSteps() }
#endif
        }
        // Paged away, the page is taken down before the selection says so:
        // what was tapped goes now.
        .onDisappear {
            WristGestureTrail.note("event page gone")
            leave()
        }
        .onChange(of: Input(subject: subject, availability: availability)) { _, new in show(new) }
        .onChange(of: pendingEventIDs) { _, ids in session.settle(pendingEventIDs: ids) }
        // The wrist going down sends what was tapped, as leaving does.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { takeCrown() } else { leave() }
        }
        .onChange(of: isVisible) { _, visible in
            WristGestureTrail.note("event page \(visible ? "shown" : "left")")
            if visible { takeCrown() } else { leave() }
        }
        .onChange(of: scrollFocused) { _, focused in
            WristGestureTrail.note("event page crown \(focused ? "taken" : "let go") visible=\(isVisible)")
        }
    }

    /// Once, after the page is in place, and only while it shows.
    private func takeCrown() {
        DispatchQueue.main.async {
            guard isVisible, !scrollFocused else { return }
            scrollFocused = true
        }
    }

    private func leave() {
        restToken = UUID()
        stepping = false
        sendUnsent()
    }

    private func show(_ input: Input) {
        if session.show(input.subject, availability: input.availability) {
            WristGestureTrail.note("event page: subject changed before the send — unsent taps dropped")
        }
    }

    /// One tap of − (-1) or +: a stop of the end, sent once the taps rest.
    /// The tap that reaches the last stop that way plays the limit's tap,
    /// and the button dims.
    private func step(_ direction: Int) {
        guard let moved = session.turn(crownDelta: direction * WristEndCrown.crownLater)?.moved, moved else { return }
        let later = direction > 0
        countsDown = !later
        WKInterfaceDevice.current().play(session.canStep(direction) ? .click : (later ? .directionUp : .directionDown))
        WristGestureTrail.note("event page: \(later ? "+" : "−") → end \(strings.clock(session.shownEnd ?? Date()))")
        stepping = true
        let token = UUID()
        restToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + WristEndCrown.restDelay) {
            guard restToken == token else { return }
            stepping = false
            sendUnsent()
        }
    }

    private func sendUnsent() {
        guard let send = session.takeUnsent(now: Date()) else { return }
        WristGestureTrail.note("event page: send \(send.occurrence.title) \(strings.timeRange(send.start, send.end))")
        onSend(send)
    }

    /// The event: its name and type, its end — large — and how long it is.
    @ViewBuilder
    private func info(_ subject: WristEventSubject, availability: WristEndCrown.Availability?) -> some View {
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
            Spacer(minLength: 4)
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
                    .foregroundStyle(changed || stepping ? accent : .white)
                    .contentTransition(.numericText(countsDown: countsDown))
                    .animation(.spring(response: 0.22, dampingFraction: 0.85), value: end)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .accessibilityLabel(strings.endLabel)
                    .accessibilityValue(strings.clock(end))
                Text(strings.durationFrom(occurrence.start, end))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Group {
                if sending, !stepping {
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
            // The end sits low at rest, so with − and + scrolled into view
            // it is still clear of the clock row on the smallest watch.
            Color.clear.frame(height: 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// − and +: a stop of the end each, dimmed where none is left.
    private func buttons(_ subject: WristEventSubject) -> some View {
        let accent = WristColor.color(subject.occurrence.colorHex)
        return HStack(spacing: 8) {
            stepButton("minus", label: strings.endEarlier, direction: -1, fill: Color.white.opacity(0.18))
            stepButton("plus", label: strings.endLater, direction: 1, fill: accent.opacity(0.85))
        }
        .frame(height: Self.buttonHeight)
    }

    private func stepButton(_ symbol: String, label: String, direction: Int, fill: Color) -> some View {
        let enabled = session.canStep(direction)
        return Button { step(direction) } label: {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(fill, in: Capsule())
        }
        .buttonStyle(WristPressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .animation(.easeOut(duration: 0.15), value: enabled)
        .accessibilityLabel(label)
    }

    /// `-wristEventRevealed` opens the page scrolled to − and +, for a
    /// screenshot without a scroll. Debug builds only.
    private static var opensRevealed: Bool {
#if DEBUG
        ProcessInfo.processInfo.arguments.contains("-wristEventRevealed")
#else
        false
#endif
    }

#if DEBUG
    /// `-wristSteps <n>` taps + (or −, negative) n times once the page is
    /// showing, through the same path a tap takes, faster than the rest
    /// delay: one send at the end. Debug builds only.
    private func seedDebugSteps() {
        let arguments = ProcessInfo.processInfo.arguments
        guard isVisible, let i = arguments.firstIndex(of: "-wristSteps"), i + 1 < arguments.count,
              let steps = Int(arguments[i + 1]), steps != 0 else { return }
        for n in 1...abs(steps) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15 * Double(n)) { step(steps.signum()) }
        }
    }
#endif
}

/// The event page's two resting places: the top (the event), or the
/// bottom (− and + fully in view, the end above them). A scroll goes on to
/// the resting place the way it went — a crown's detent or a short drag is
/// enough — and one that barely moved settles on the nearer.
struct WristTwoRestScroll: ScrollTargetBehavior {
    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let maxY = max(0, context.contentSize.height - context.containerSize.height)
        guard maxY > 0 else { return }
        let from = context.originalTarget.rect.minY
        let to = target.rect.minY
        if to > from + 2 {
            target.rect.origin.y = maxY
        } else if to < from - 2 {
            target.rect.origin.y = 0
        } else {
            target.rect.origin.y = to > maxY / 2 ? maxY : 0
        }
    }
}

/// A button pressed: a little smaller and brighter, back with a spring.
struct WristPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .brightness(configuration.isPressed ? 0.12 : 0)
            .animation(.spring(response: 0.2, dampingFraction: 0.65), value: configuration.isPressed)
    }
}
