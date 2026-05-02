import SwiftUI

struct FocusModeEventView: View {
    let event: Event
    let range: Event.TimeRange
    let now: Date
    let allOccurrences: [CalendarLayout.EventOccurrence]
    var isPortrait: Bool = false
    /// When false, +15/End now/title-edit are hidden because the current
    /// event can't be safely mutated by simple direct paths (e.g. it's a
    /// recurring occurrence that would need scope-aware editing). Caller
    /// decides via `focusQuickActionAllowedForEvent`.
    /// Note: Interrupt is *not* gated on this flag — creating an interrupt
    /// adds a new linked event without touching the parent's series template,
    /// so it's safe on recurring parents.
    var quickActionsEnabled: Bool = true
    /// Type templates available for quick-creating an interrupt under the
    /// current event. Empty disables the Interrupt pill.
    var templates: [EventTypeTemplate] = []
    /// Quick-action: extend the current event's end by the supplied delta
    /// (in seconds). Caller decides whether to apply to the series or the
    /// occurrence.
    var onExtend: (TimeInterval) -> Void = { _ in }
    /// Quick-action: end the current event at "now".
    var onEndNow: () -> Void = {}
    /// Inline title commit. Called with the trimmed new title when the
    /// user finishes editing. Empty string means "user cleared the title"
    /// — the data layer accepts that; the view falls back to "Untitled"
    /// in display when reading an empty stored title.
    var onUpdateTitle: (String) -> Void = { _ in }
    /// Append a timestamped timeline note to the current event. Caller
    /// builds the occurrence context and stamps the createdAt.
    var onAddNote: (String) -> Void = { _ in }
    /// Create an embedded interrupt under the current event with the
    /// chosen type name. Caller handles the time range and store wiring.
    var onCreateInterrupt: (String) -> Void = { _ in }

    @State private var titleDraft: String = ""
    @State private var isEditingTitle: Bool = false
    @FocusState private var titleFieldFocused: Bool

    @State private var noteDraft: String = ""
    @State private var isComposingNote: Bool = false
    @FocusState private var noteFieldFocused: Bool

    @State private var isPickingInterruptType: Bool = false

    private let noteCommitHaptic = UISelectionFeedbackGenerator()
    private let interruptCommitHaptic = UISelectionFeedbackGenerator()

    private var eventColor: Color {
        CalendarLayout.eventColor(for: event)
    }

    /// Progress label and whether the contract is over its agreed end time.
    /// Replaces the old continuous-arc ring whose visual fidelity contradicted
    /// the app's 15-min snap philosophy. The label is the single visual
    /// anchor for "where am I in this contract" — no ring, just a number.
    private var progressDisplay: (text: String, isOverrun: Bool) {
        let delta = range.end.timeIntervalSince(now)
        if delta >= 0 {
            let mins = Int(delta) / 60
            if mins >= 60 {
                let h = mins / 60
                let m = mins % 60
                return (m > 0 ? "\(h)h \(m)m left" : "\(h)h left", false)
            }
            return ("\(mins)m left", false)
        }
        let over = -delta
        let mins = Int(over) / 60
        if mins >= 60 {
            let h = mins / 60
            let m = mins % 60
            return (m > 0 ? "\(h)h \(m)m over" : "\(h)h over", true)
        }
        return ("\(max(0, mins))m over", true)
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
        ZStack {
            // Tap-outside-to-dismiss layer: only active while inline title
            // editing is in progress. Sits behind the layout so taps on
            // the TextField, the +15/End-now buttons, type pill, etc.
            // still hit their own targets first; only taps in the empty
            // areas (Spacers, padding) fall through to here.
            if isEditingTitle {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { titleFieldFocused = false }
            }

            if isPortrait {
                portraitLayout
            } else {
                landscapeLayout
            }
        }
    }

    private var landscapeLayout: some View {
        HStack(spacing: 0) {
            // Left: event flow — ambient time context
            FocusEventFlowView(
                currentEvent: event,
                currentRange: range,
                now: now,
                allOccurrences: allOccurrences
            )
            .frame(maxHeight: .infinity)
            .frame(maxWidth: .infinity)
            .padding(.leading, 48)

            // Right: focus session — protagonist
            VStack(spacing: 20) {
                Spacer()
                eventDetailStack(titleSize: 40, progressSize: 28)
                quickActionRow
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        }
    }

    private var portraitLayout: some View {
        // Symmetric: prev chip on top, big protagonist centered, next chip
        // on bottom. Keeps the focus on the current event without competing
        // with a full mini-timeline (the calendar tab already covers that
        // role). Same chip vocabulary as the empty-state clock view, so
        // the two states feel like one design.
        VStack(spacing: 16) {
            if previousOccurrence != nil {
                FocusAmbientChip(
                    kind: .previous,
                    occurrence: previousOccurrence,
                    referenceDate: now
                )
            }

            Spacer()

            VStack(spacing: 18) {
                eventDetailStack(titleSize: 44, progressSize: 36)
                quickActionRow
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
    private var quickActionRow: some View {
        VStack(spacing: 12) {
            // Row 1: time / structure verbs. Time mutations gated on
            // quickActionsEnabled (recurring guard); Interrupt is always
            // available because it adds a new linked event rather than
            // mutating the parent series template.
            HStack(spacing: 10) {
                if quickActionsEnabled {
                    actionPill(label: "+15 min", systemImage: "clock.arrow.circlepath") {
                        onExtend(15 * 60)
                    }
                    actionPill(label: "End now", systemImage: "stop.circle", role: .destructive) {
                        onEndNow()
                    }
                }
                if !templates.isEmpty {
                    actionPill(
                        label: isPickingInterruptType ? "Cancel" : "Interrupt",
                        systemImage: isPickingInterruptType ? "xmark.circle" : "bolt.fill",
                        role: isPickingInterruptType ? .destructive : nil
                    ) {
                        toggleInterruptPicker()
                    }
                }
            }

            if isPickingInterruptType {
                interruptTypePicker
            }

            // Row 2: capture verbs. Note has its own composer expansion
            // below — kept on its own row so the composer + send button
            // breathe.
            if quickActionsEnabled {
                HStack(spacing: 10) {
                    actionPill(
                        label: isComposingNote ? "Cancel" : "Note",
                        systemImage: isComposingNote ? "xmark.circle" : "note.text",
                        role: isComposingNote ? .destructive : nil
                    ) {
                        toggleNoteComposer()
                    }
                }

                if isComposingNote {
                    noteComposer
                }
            }
        }
    }

    private var interruptTypePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(templates) { template in
                    interruptTypePill(template)
                }
            }
            .padding(.horizontal, 4)
        }
        .frame(maxWidth: 480)
    }

    private func interruptTypePill(_ template: EventTypeTemplate) -> some View {
        let color = ColorHex.toColor(template.colorHex)
        return Button {
            onCreateInterrupt(template.title)
            interruptCommitHaptic.selectionChanged()
            isPickingInterruptType = false
        } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(template.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Capsule().fill(color.opacity(0.15)))
            .overlay(Capsule().stroke(color.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func toggleInterruptPicker() {
        if isPickingInterruptType {
            isPickingInterruptType = false
        } else {
            // Mutually exclusive with note composer — opening one closes
            // the other so we never stack two expansions.
            isComposingNote = false
            noteFieldFocused = false
            isPickingInterruptType = true
            interruptCommitHaptic.prepare()
        }
    }

    private var noteComposer: some View {
        HStack(alignment: .center, spacing: 8) {
            TextField("What's happening?", text: $noteDraft)
                .focused($noteFieldFocused)
                .submitLabel(.send)
                .onSubmit { commitNote() }
                .onChange(of: noteFieldFocused) { _, focused in
                    // Tap-outside (focus loss) collapses the composer
                    // only if the draft is empty. Non-empty drafts stay
                    // visible so the user can resume typing or hit send
                    // without re-typing — data preservation extends to
                    // in-progress drafts too.
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
        .frame(maxWidth: 360)
    }

    private func toggleNoteComposer() {
        if isComposingNote {
            // Cancel: drop the draft.
            noteDraft = ""
            isComposingNote = false
            noteFieldFocused = false
        } else {
            // Mutually exclusive with interrupt picker.
            isPickingInterruptType = false
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

    private func actionPill(
        label: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                Text(label)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(role == .destructive ? Color.red : Color.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
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

    @ViewBuilder
    private func eventDetailStack(titleSize: CGFloat, progressSize: CGFloat) -> some View {
        // Type chip in event state: outline-only, deliberately distinct
        // from the start-tracking pills (filled capsule + colored dot)
        // shown in the empty/idle state. Same color, different visual
        // weight: filled = action, outlined = badge. Resolves the
        // affordance collision flagged in design review.
        Text(event.type)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(eventColor)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .overlay(
                Capsule().stroke(eventColor.opacity(0.65), lineWidth: 1.4)
            )

        titleView(size: titleSize)

        // Progress as the new visual anchor — single line, monospaced,
        // honest about discrete time. Red + warning glyph when the
        // contract has overrun its agreed end (the icon is non-color
        // signal, color alone is not accessible).
        HStack(spacing: 8) {
            if progressDisplay.isOverrun {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: progressSize * 0.55, weight: .semibold))
            }
            Text(progressDisplay.text)
                .font(.system(size: progressSize, weight: .bold, design: .rounded).monospacedDigit())
        }
        .foregroundStyle(progressDisplay.isOverrun ? Color.red : Color.primary)

        Text("\(timeText(range.start)) – \(timeText(range.end))")
            .font(.system(size: 16, weight: .regular, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func titleView(size: CGFloat) -> some View {
        if isEditingTitle {
            TextField("Untitled", text: $titleDraft)
                .focused($titleFieldFocused)
                .submitLabel(.done)
                .onSubmit { titleFieldFocused = false }
                .onChange(of: titleFieldFocused) { _, focused in
                    // Commit on focus loss covers all dismiss paths:
                    // Done key on keyboard, swipe-down on keyboard,
                    // tap-outside-the-field (the Color.clear catcher
                    // behind the layout), and tap on +15 / End now
                    // (which moves UIResponder focus to the button).
                    if !focused { commitTitleEdit() }
                }
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                )
        } else {
            Text(event.title.isEmpty ? "Untitled" : event.title)
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(event.title.isEmpty ? .secondary : .primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    // Subtle background pill signals tappability — the
                    // title is the most-edited field but had no visual
                    // affordance before. Just enough tint to read as
                    // "you can tap here," not as a prominent button.
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.secondary.opacity(0.06))
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    guard quickActionsEnabled else { return }
                    titleDraft = event.title
                    isEditingTitle = true
                    titleFieldFocused = true
                }
        }
    }

    private func commitTitleEdit() {
        if let resolved = focusTitleCommitValue(draft: titleDraft, current: event.title) {
            onUpdateTitle(resolved)
        }
        isEditingTitle = false
    }
}
