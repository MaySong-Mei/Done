import SwiftUI

/// Focus mode's in-event surface: an ambient "screensaver" rendering of
/// the currently-tracked event, with a few light interactions wired
/// alongside (extend / shorten / end / add note). Editing the event's
/// metadata (title, type, recurrence, etc.) is intentionally NOT here —
/// that lives in the calendar's event detail. Focus is a beautiful
/// glance, not a workspace.
struct FocusModeEventView: View {
    let event: Event
    let range: Event.TimeRange
    let now: Date
    let allOccurrences: [CalendarLayout.EventOccurrence]
    var isPortrait: Bool = false
    /// When false, the time-mutation pills (+15 / -15 / End now) are
    /// hidden because the current event can't be safely mutated by a
    /// direct path — e.g. it's a recurring occurrence that would need
    /// scope-aware editing. The Note pill stays available because notes
    /// attach to the occurrence's log record, not the series template.
    var quickActionsEnabled: Bool = true
    /// Adjust the event's end by the given delta (seconds).
    var onExtend: (TimeInterval) -> Void = { _ in }
    /// End the event at "now".
    var onEndNow: () -> Void = {}
    /// Append a timestamped timeline note.
    var onAddNote: (String) -> Void = { _ in }

    @State private var noteDraft: String = ""
    @State private var isComposingNote: Bool = false
    @FocusState private var noteFieldFocused: Bool

    // Experimental: gate the landscape mini-cal between the SwiftUI
    // `FocusEventFlowView` tree and the CALayer-backed
    // `FocusEventFlowLayerHost`. Default OFF until A/B parity is verified
    // (mirrors the #60→#74 / #71 arcs). See issue #72.
    @AppStorage(AppSettingsKeys.calendarUseCALayerFocusEventFlow)
    private var useCALayerFocusEventFlow = false

    private let noteCommitHaptic = UISelectionFeedbackGenerator()

    private var eventColor: Color {
        CalendarLayout.eventColor(for: event)
    }

    private var elapsed: TimeInterval {
        max(0, now.timeIntervalSince(range.start))
    }

    private var total: TimeInterval {
        max(1, range.end.timeIntervalSince(range.start))
    }

    private var progress: Double {
        min(1, elapsed / total)
    }

    private var remainingText: String {
        let remaining = max(0, range.end.timeIntervalSince(now))
        let mins = Int(remaining) / 60
        if mins >= 60 {
            let h = mins / 60
            let m = mins % 60
            return m > 0 ? "\(h)h \(m)m left" : "\(h)h left"
        }
        return "\(mins)m left"
    }

    private var previousOccurrence: CalendarLayout.EventOccurrence? {
        allOccurrences
            .filter { $0.range.end <= now && $0.event.id != event.id }
            .max(by: { $0.range.end < $1.range.end })
    }

    private var nextOccurrence: CalendarLayout.EventOccurrence? {
        allOccurrences
            .filter { $0.range.start >= range.end }
            .min(by: { $0.range.start < $1.range.start })
    }

    private func timeText(_ date: Date) -> String {
        let f = DateFormatter()
        if AppTimeFormat.current.is24 {
            f.dateFormat = "H:mm"
        } else {
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "h:mm a"
            f.amSymbol = "am"
            f.pmSymbol = "pm"
        }
        return f.string(from: date)
    }

    var body: some View {
        if isPortrait {
            portraitLayout
        } else {
            landscapeLayout
        }
    }

    /// Original-spirit landscape layout: FocusEventFlowView mini-cal on
    /// the left as ambient time context, the protagonist column on the
    /// right with a circular progress ring as the visual anchor.
    private var landscapeLayout: some View {
        HStack(spacing: 0) {
            Group {
                if useCALayerFocusEventFlow {
                    FocusEventFlowLayerHost(
                        now: now,
                        allOccurrences: allOccurrences
                    )
                } else {
                    FocusEventFlowView(
                        currentEvent: event,
                        currentRange: range,
                        now: now,
                        allOccurrences: allOccurrences
                    )
                }
            }
            .frame(maxHeight: .infinity)
            .frame(maxWidth: .infinity)
            .padding(.leading, 48)

            VStack(spacing: 22) {
                Spacer()
                eventDetailStack(titleSize: 40, ringSize: 110)
                quickActionRow
                if isComposingNote {
                    noteComposer
                        .frame(maxWidth: 420)
                }
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        }
    }

    /// Portrait counterpart — same vibe, no side mini-cal (would crowd
    /// a vertical screen). Prev/next chips clear of the status bar
    /// (`.padding(.top, 32)` is load-bearing — `.safeAreaPadding` alone
    /// doesn't fully clear the dynamic island in this hierarchy). The
    /// protagonist sits in the upper-middle area: a constrained top
    /// spacer gives a small read gap from the prev chip, the bottom
    /// spacer takes whatever remains.
    private var portraitLayout: some View {
        VStack(spacing: 0) {
            if previousOccurrence != nil {
                FocusAmbientChip(
                    kind: .previous,
                    occurrence: previousOccurrence,
                    referenceDate: now
                )
                .padding(.top, 8)
            }

            Spacer().frame(maxHeight: 72)

            VStack(spacing: 22) {
                eventDetailStack(titleSize: 44, ringSize: 200)
                quickActionRow
                if isComposingNote {
                    noteComposer
                }
            }

            Spacer()

            if nextOccurrence != nil {
                FocusAmbientChip(
                    kind: .next,
                    occurrence: nextOccurrence,
                    referenceDate: range.end
                )
                .padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaPadding(.vertical)
    }

    @ViewBuilder
    private func eventDetailStack(titleSize: CGFloat, ringSize: CGFloat) -> some View {
        // Type chip dropped on purpose — the ring's color already
        // encodes the event type, and a separate pill on top of the
        // title plus a time-range row was three vertical bands of
        // text fighting the ring for visual weight.
        Text(event.title.isEmpty ? "Untitled" : event.title)
            .font(.system(size: titleSize, weight: .semibold, design: .rounded))
            .lineLimit(2)
            .multilineTextAlignment(.center)

        Text("\(timeText(range.start)) – \(timeText(range.end))")
            .font(.system(size: 16, weight: .regular, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)

        // Circular progress ring — the visual anchor. Type is implicit
        // in its color.
        ZStack {
            Circle()
                .stroke(eventColor.opacity(0.2), lineWidth: 8)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(eventColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))

            Text(remainingText)
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(width: ringSize, height: ringSize)
    }

    @ViewBuilder
    private var quickActionRow: some View {
        if quickActionsEnabled {
            HStack(spacing: 10) {
                actionPill(label: "−15") { onExtend(-15 * 60) }
                actionPill(label: "+15") { onExtend(15 * 60) }
                actionPill(
                    label: "End",
                    systemImage: "stop.circle",
                    role: .destructive
                ) { onEndNow() }
                actionPill(
                    label: isComposingNote ? "Cancel" : "Note",
                    systemImage: isComposingNote ? "xmark.circle" : "note.text",
                    role: isComposingNote ? .destructive : nil
                ) { toggleNoteComposer() }
            }
        } else {
            // Recurring events: only Note is safe (occurrence-keyed log).
            HStack(spacing: 10) {
                actionPill(
                    label: isComposingNote ? "Cancel" : "Note",
                    systemImage: isComposingNote ? "xmark.circle" : "note.text",
                    role: isComposingNote ? .destructive : nil
                ) { toggleNoteComposer() }
            }
        }
    }

    /// `systemImage = nil` renders text-only — used for the +15/−15
    /// pills, where a separate `+`/`−` glyph would just duplicate the
    /// sign already in the label.
    private func actionPill(
        label: String,
        systemImage: String? = nil,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(label)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .foregroundStyle(role == .destructive ? Color.red : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                Capsule().fill(
                    role == .destructive
                        ? Color.red.opacity(0.10)
                        : Color.secondary.opacity(0.12)
                )
            )
        }
        .buttonStyle(.plain)
    }

    private var noteComposer: some View {
        HStack(alignment: .center, spacing: 8) {
            TextField("What's happening?", text: $noteDraft)
                .focused($noteFieldFocused)
                .submitLabel(.send)
                .onSubmit { commitNote() }
                .onChange(of: noteFieldFocused) { _, focused in
                    if !focused && noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        isComposingNote = false
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.secondary.opacity(0.10))
                )

            Button { commitNote() } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(
                        noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Color.secondary.opacity(0.4)
                            : Color.accentColor
                    )
            }
            .buttonStyle(.plain)
            .disabled(noteDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func toggleNoteComposer() {
        if isComposingNote {
            noteDraft = ""
            isComposingNote = false
            noteFieldFocused = false
        } else {
            noteDraft = ""
            isComposingNote = true
            noteFieldFocused = true
            noteCommitHaptic.prepare()
        }
    }

    private func commitNote() {
        guard let text = focusNoteCommitText(draft: noteDraft) else { return }
        onAddNote(text)
        noteCommitHaptic.selectionChanged()
        noteDraft = ""
        isComposingNote = false
        noteFieldFocused = false
    }
}
