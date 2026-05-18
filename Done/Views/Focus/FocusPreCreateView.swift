import SwiftUI

/// Pre-create preview surface — the "entry ceremony" before crossing into
/// the inhabiting state. Shown only when "Confirm Before Tracking" is on
/// and the user taps a type pill from the idle clock view. The user names
/// the event, manipulates its time on the embedded mini-cal picker, and
/// confirms — at which point the event is created and the view
/// transitions into the inhabiting state.
///
/// This is intent-setting, not a creation form. The picker IS the
/// time-selection interaction; there are no ±buttons. Visual quietness,
/// the type's color used as the cue, minimal chrome.
struct FocusPreCreateView: View {
    let template: EventTypeTemplate
    let now: Date
    let proposedStart: Date
    let allOccurrences: [CalendarLayout.EventOccurrence]
    var isPortrait: Bool = false
    var onConfirm: (_ title: String, _ start: Date, _ end: Date) -> Void = { _, _, _ in }
    var onCancel: () -> Void = {}

    @State private var title: String
    @State private var startDate: Date
    @State private var endDate: Date
    @FocusState private var titleFieldFocused: Bool

    private static let defaultDuration: TimeInterval = 30 * 60

    init(
        template: EventTypeTemplate,
        now: Date,
        proposedStart: Date,
        allOccurrences: [CalendarLayout.EventOccurrence],
        isPortrait: Bool = false,
        onConfirm: @escaping (_ title: String, _ start: Date, _ end: Date) -> Void = { _, _, _ in },
        onCancel: @escaping () -> Void = {}
    ) {
        self.template = template
        self.now = now
        self.proposedStart = proposedStart
        self.allOccurrences = allOccurrences
        self.isPortrait = isPortrait
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        // Title starts empty — naming is an *explicit* step in the
        // entry ceremony. The type name shows as placeholder so the
        // user sees what the fallback will be; the type cue chip below
        // keeps the type identity visible whether or not they name it.
        _title = State(initialValue: "")
        _startDate = State(initialValue: proposedStart)
        _endDate = State(initialValue: proposedStart.addingTimeInterval(Self.defaultDuration))
    }

    /// Resolve the type's color through the same path TimelineView
    /// uses (`CalendarLayout.eventColor` → `EventTypeTemplateStore.color`),
    /// not the template's raw `colorHex`. Keeps the slot's color
    /// identical to how the event will render once it lands in the
    /// calendar.
    private var typeColor: Color {
        EventTypeTemplateStore.color(for: template.title)
    }

    private var rangeText: String {
        "\(timeText(startDate)) – \(timeText(endDate))"
    }

    private var durationText: String {
        let minutes = max(0, Int(endDate.timeIntervalSince(startDate)) / 60)
        if minutes >= 60 {
            let h = minutes / 60
            let m = minutes % 60
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        return "\(minutes)m"
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What the picker block renders inside its slot — the live name
    /// the user is typing, falling back to the type name. Keeps the
    /// slot reading as a real calendar event block.
    private var resolvedSlotTitle: String {
        trimmedTitle.isEmpty ? template.title : trimmedTitle
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

    private func commit() {
        let finalTitle = trimmedTitle.isEmpty ? template.title : trimmedTitle
        onConfirm(finalTitle, startDate, endDate)
    }

    var body: some View {
        if isPortrait {
            portraitLayout
        } else {
            landscapeLayout
        }
    }

    /// Landscape: picker is a constrained slice on the left (capped
    /// width + height so it doesn't sprawl), the meta block on the
    /// right takes the rest. Same vertical structure as portrait —
    /// name · type, then time + duration — just placed alongside the
    /// picker instead of above it.
    private var landscapeLayout: some View {
        HStack(spacing: 0) {
            FocusPreCreatePicker(
                startDate: $startDate,
                endDate: $endDate,
                now: now,
                allOccurrences: allOccurrences,
                typeColor: typeColor,
                slotTitle: resolvedSlotTitle
            )
            .frame(maxWidth: 360, maxHeight: 320)
            .padding(.leading, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

            VStack(alignment: .leading, spacing: 18) {
                Spacer()
                topMetaBlock(nameSize: 22)
                Spacer()
                actionRow
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
        }
    }

    /// Portrait: meta block (name · type / time duration) sits at the
    /// top, picker takes the middle region (the protagonist), action
    /// row at the bottom. Constrained top spacer keeps the meta clear
    /// of the dynamic island.
    private var portraitLayout: some View {
        VStack(spacing: 14) {
            Spacer().frame(maxHeight: 36)

            topMetaBlock(nameSize: 20)

            Spacer(minLength: 12)

            FocusPreCreatePicker(
                startDate: $startDate,
                endDate: $endDate,
                now: now,
                allOccurrences: allOccurrences,
                typeColor: typeColor,
                slotTitle: resolvedSlotTitle
            )
            .frame(maxWidth: .infinity)
            .frame(minHeight: 280, maxHeight: 380)

            Spacer(minLength: 16)

            actionRow
                .padding(.bottom, 4)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaPadding(.vertical)
    }

    /// Two-line meta block: `[name] · [type]` on top, `[time] [duration]`
    /// underneath. Default name reads as a sentence ("a Exercise event"),
    /// no underline — tap-to-edit is signalled by the pencil glyph
    /// alone, swapping in for a plain TextField when focused.
    @ViewBuilder
    private func topMetaBlock(nameSize: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                nameField(size: nameSize)
                Text("·")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.5))
                typeChip
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(rangeText)
                    .font(.system(size: 14, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(durationText)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Plain-text-with-pencil name field. Default placeholder reads
    /// "a [type] event" — the field looks like prose until the user
    /// taps. No underline (the user explicitly didn't want a `一横`
    /// affordance); the pencil + the natural keyboard pop are the
    /// only edit cues.
    private func nameField(size: CGFloat) -> some View {
        let placeholder = "a \(template.title) event"
        return HStack(spacing: 6) {
            TextField(placeholder, text: $title)
                .focused($titleFieldFocused)
                .submitLabel(.done)
                .onSubmit { titleFieldFocused = false }
                .font(.system(size: size, weight: .semibold, design: .rounded))
                .foregroundStyle(title.isEmpty ? Color.secondary.opacity(0.65) : Color.primary)
                .lineLimit(1)
                .layoutPriority(1)

            if !titleFieldFocused {
                Image(systemName: "pencil")
                    .font(.system(size: max(11, size * 0.5), weight: .semibold))
                    .foregroundStyle(.secondary.opacity(0.45))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { titleFieldFocused = true }
    }

    private var typeChip: some View {
        HStack(spacing: 5) {
            Circle().fill(typeColor).frame(width: 7, height: 7)
            Text(template.title)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button {
                onCancel()
            } label: {
                Text(L(.cancel))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(Color.secondary.opacity(0.14)))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)

            Button {
                commit()
            } label: {
                Text("Begin")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 26)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(typeColor.opacity(0.95)))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
    }
}
