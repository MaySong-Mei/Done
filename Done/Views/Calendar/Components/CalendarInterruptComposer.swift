import SwiftUI
import UIKit
import Combine

let calendarInterruptDurationStepMinutes = 15
let calendarInterruptDefaultDurationMinutes = 30
let calendarInterruptMinimumDuration: TimeInterval = 15 * 60

func calendarInterruptClampedRange(
    parentRange: Event.TimeRange,
    desiredStart: Date,
    durationMinutes: Int,
    minimumDuration: TimeInterval = calendarInterruptMinimumDuration
) -> Event.TimeRange {
    let requestedDuration = max(minimumDuration, TimeInterval(durationMinutes * 60))
    var start = min(max(desiredStart, parentRange.start), parentRange.end)
    var end = start.addingTimeInterval(requestedDuration)

    if end > parentRange.end {
        start = max(parentRange.start, parentRange.end.addingTimeInterval(-requestedDuration))
        end = start.addingTimeInterval(requestedDuration)
    }

    if start < parentRange.start {
        start = parentRange.start
    }
    if end > parentRange.end {
        end = parentRange.end
    }
    if end <= start {
        end = min(parentRange.end, start.addingTimeInterval(minimumDuration))
    }

    return Event.TimeRange(start: start, end: end)
}

func calendarInterruptMergedOccupiedRanges(
    parentRange: Event.TimeRange,
    occupiedRanges: [Event.TimeRange]
) -> [Event.TimeRange] {
    let clipped = occupiedRanges.compactMap { range -> Event.TimeRange? in
        let start = max(range.start, parentRange.start)
        let end = min(range.end, parentRange.end)
        guard end > start else { return nil }
        return Event.TimeRange(start: start, end: end)
    }
    .sorted {
        if $0.start == $1.start {
            return $0.end < $1.end
        }
        return $0.start < $1.start
    }

    guard var current = clipped.first else { return [] }
    var merged: [Event.TimeRange] = []

    for range in clipped.dropFirst() {
        if range.start <= current.end {
            current.end = max(current.end, range.end)
        } else {
            merged.append(current)
            current = range
        }
    }
    merged.append(current)
    return merged
}

func calendarInterruptAvailableRanges(
    parentRange: Event.TimeRange,
    occupiedRanges: [Event.TimeRange]
) -> [Event.TimeRange] {
    let merged = calendarInterruptMergedOccupiedRanges(
        parentRange: parentRange,
        occupiedRanges: occupiedRanges
    )
    guard !merged.isEmpty else { return [parentRange] }

    var available: [Event.TimeRange] = []
    var cursor = parentRange.start

    for range in merged {
        if range.start > cursor {
            available.append(Event.TimeRange(start: cursor, end: range.start))
        }
        cursor = max(cursor, range.end)
    }

    if cursor < parentRange.end {
        available.append(Event.TimeRange(start: cursor, end: parentRange.end))
    }

    return available
}

func calendarInterruptDefaultQuickRange(
    now: Date,
    parentRange: Event.TimeRange,
    durationMinutes: Int,
    calendar: Calendar = .current
) -> Event.TimeRange {
    calendarInterruptDefaultQuickRange(
        now: now,
        parentRange: parentRange,
        durationMinutes: durationMinutes,
        occupiedRanges: [],
        calendar: calendar
    )
}

func calendarInterruptDefaultQuickRange(
    now: Date,
    parentRange: Event.TimeRange,
    durationMinutes: Int,
    occupiedRanges: [Event.TimeRange],
    calendar: Calendar = .current
) -> Event.TimeRange {
    let anchorSource: Date
    if (parentRange.start...parentRange.end).contains(now) {
        anchorSource = calendar.date(
            bySettingHour: calendar.component(.hour, from: now),
            minute: calendar.component(.minute, from: now),
            second: 0,
            of: now
        ) ?? now
    } else {
        let requestedDuration = max(
            calendarInterruptMinimumDuration,
            TimeInterval(durationMinutes * 60)
        )
        let availableRanges = calendarInterruptAvailableRanges(
            parentRange: parentRange,
            occupiedRanges: occupiedRanges
        )

        if let bestRange = availableRanges.max(by: { lhs, rhs in
            let lhsDuration = lhs.end.timeIntervalSince(lhs.start)
            let rhsDuration = rhs.end.timeIntervalSince(rhs.start)
            if abs(lhsDuration - rhsDuration) > 0.5 {
                return lhsDuration < rhsDuration
            }
            return lhs.end < rhs.end
        }) {
            anchorSource = max(
                parentRange.start,
                bestRange.end.addingTimeInterval(-requestedDuration)
            )
        } else {
            anchorSource = max(
                parentRange.start,
                parentRange.end.addingTimeInterval(-requestedDuration)
            )
        }
    }
    return calendarInterruptClampedRange(
        parentRange: parentRange,
        desiredStart: anchorSource,
        durationMinutes: durationMinutes
    )
}

func calendarInterruptDurationFromScrub(
    baseMinutes: Int,
    translationX: CGFloat,
    pointsPerStep: CGFloat = 28
) -> Int {
    guard pointsPerStep > 0 else {
        return max(calendarInterruptDurationStepMinutes, baseMinutes)
    }
    let deltaSteps = Int((translationX / pointsPerStep).rounded())
    let deltaMinutes = deltaSteps * calendarInterruptDurationStepMinutes
    return max(calendarInterruptDurationStepMinutes, baseMinutes + deltaMinutes)
}

private struct CalendarInterruptComposerHeader: View {
    let liveMode: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 34, height: 34)
                Image(systemName: liveMode ? "bolt.fill" : "sparkles")
                    .font(.system(size: 14, weight: .semibold))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(L(.detailInterrupt))
                    .font(.system(size: 15, weight: .semibold))
                Text(liveMode ? L(.captureLiveInterruption) : L(.createParallelInterruption))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }
}

struct CalendarInterruptComposer: View {
    let anchorPoint: CGPoint
    let parentRange: Event.TimeRange
    let occupiedRanges: [Event.TimeRange]
    let parentTypeTitle: String
    let onCreate: (String, String, Event.TimeRange) -> Void
    let onStartLive: (String, String) -> Void
    let onDismiss: () -> Void

    @EnvironmentObject private var store: EventStore
    @StateObject private var templateStore = EventTypeTemplateStore()
    @State private var title: String = ""
    @State private var typeTitle: String = ""
    @State private var didExplicitlySelectType = false
    @State private var automaticTypeSelectionTask: Task<Void, Never>?
    @State private var durationMinutes: Int = calendarInterruptDefaultDurationMinutes
    @State private var liveMode = false
    @State private var appeared = false
    @State private var dragBaseDuration: Int?
    @State private var lastScrubDuration: Int = calendarInterruptDefaultDurationMinutes
    @State private var previewAnchorNow: Date = Date()

    private let impactFeedback = UIImpactFeedbackGenerator(style: .light)

    private var previewRange: Event.TimeRange {
        calendarInterruptDefaultQuickRange(
            now: previewAnchorNow,
            parentRange: parentRange,
            durationMinutes: durationMinutes,
            occupiedRanges: occupiedRanges
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let menuSize = CGSize(width: 252, height: liveMode ? 252 : 262)
            let bottomInset = proxy.safeAreaInsets.bottom
            let position = menuPosition(
                anchor: anchorPoint,
                menuSize: menuSize,
                containerSize: proxy.size,
                bottomInset: bottomInset
            )

            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { onDismiss() }

                VStack(alignment: .leading, spacing: 14) {
                    CalendarInterruptComposerHeader(liveMode: liveMode)

                    VStack(alignment: .leading, spacing: 6) {
                        TextField(L(.detailInterrupt), text: $title)
                            .textFieldStyle(.plain)
                            .font(.system(size: 16, weight: .semibold))

                        ScrollViewReader { scrollProxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(templateStore.templates) { template in
                                    let selected = typeTitle == template.title
                                    Button {
                                        typeTitle = template.title
                                        didExplicitlySelectType = true
                                    } label: {
                                        let textColor: Color = selected ? .primary : .primary.opacity(0.6)
                                        let bgColor: Color = selected ? Color.primary.opacity(0.15) : Color.secondary.opacity(0.08)
                                        HStack(spacing: 5) {
                                            Circle()
                                                .fill(ColorHex.toColor(template.colorHex))
                                                .frame(width: 6, height: 6)
                                            Text(template.title)
                                                .fixedSize()
                                        }
                                        .font(.system(size: 12, weight: .medium))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(bgColor)
                                        .foregroundStyle(textColor)
                                        .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .id(template.title)
                                }
                            }
                        }
                        .onChange(of: typeTitle) {
                            withAnimation {
                                scrollProxy.scrollTo(typeTitle, anchor: .center)
                            }
                        }
                        }

                        if !liveMode {
                            Text("\(Self.timeFormatter.string(from: previewRange.start)) - \(Self.timeFormatter.string(from: previewRange.end))")
                                .font(.system(size: 12, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                        } else {
                            Text(L(.startsNowCommits))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    HStack(spacing: 8) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                liveMode.toggle()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: liveMode ? "bolt.fill" : "clock")
                                    .font(.system(size: 11, weight: .semibold))
                                Text(liveMode ? L(.liveOn) : L(.liveOff))
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 32)
                            .contentShape(Capsule())
                            .background(liveMode ? Color.primary.opacity(0.14) : Color.black.opacity(0.001), in: Capsule())
                            .glassEffect(.regular.interactive(), in: Capsule())
                        }
                        .buttonStyle(.plain)

                        Spacer(minLength: 0)


                        if !liveMode {
                            durationControl
                        }
                    }

                    HStack(spacing: 10) {
                        Button {
                            onDismiss()
                        } label: {
                            Text(L(.cancel))
                                .font(.system(size: 14, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                                .contentShape(Capsule())
                                .background(Color.black.opacity(0.001), in: Capsule())
                                .glassEffect(.regular.interactive(), in: Capsule())
                        }
                        .buttonStyle(.plain)

                        Button {
                            if liveMode {
                                onStartLive(trimmedTitle, trimmedTypeTitle)
                            } else {
                                onCreate(trimmedTitle, trimmedTypeTitle, previewRange)
                            }
                        } label: {
                            Text(liveMode ? L(.startLive) : L(.create))
                                .font(.system(size: 14, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                                .contentShape(Capsule())
                                .background(Color.primary.opacity(0.12), in: Capsule())
                                .glassEffect(.regular.interactive(), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(14)
                .frame(width: menuSize.width)
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(.white.opacity(0.18), lineWidth: 0.8)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(.white.opacity(0.06))
                        }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 18, x: 0, y: 10)
                .offset(x: position.x, y: position.y)
                .scaleEffect(appeared ? 1 : 0.82, anchor: .top)
                .opacity(appeared ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onAppear {
            impactFeedback.prepare()
            previewAnchorNow = Date()
            lastScrubDuration = durationMinutes
            if typeTitle.isEmpty {
                typeTitle = parentTypeTitle
            }
            withAnimation(.spring(duration: 0.24, bounce: 0.15)) {
                appeared = true
            }
        }
        .onChange(of: title) {
            scheduleAutomaticTypeSelection()
        }
        .onDisappear {
            automaticTypeSelectionTask?.cancel()
        }
    }

    private var trimmedTitle: String {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Interrupt" : value
    }

    private var trimmedTypeTitle: String {
        typeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func scheduleAutomaticTypeSelection() {
        automaticTypeSelectionTask?.cancel()
        guard !didExplicitlySelectType else { return }

        let rawText = calendarTypeSuggestionRawText(title: title, note: "")
        let availableTypes = templateStore.templates.map(\.title)
        let currentTypeTitle = typeTitle
        let historicalEvents = store.rawCalendarEvents

        automaticTypeSelectionTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled, !didExplicitlySelectType else { return }

            if let suggestion = calendarPreferredLocalTypeSuggestion(
                rawText: rawText,
                availableTypes: availableTypes,
                historicalEvents: historicalEvents
            ), suggestion.typeTitle != currentTypeTitle {
                typeTitle = suggestion.typeTitle
            }
        }
    }

    private var durationControl: some View {
        HStack(spacing: 0) {
            Button {
                updateDuration(max(calendarInterruptDurationStepMinutes, durationMinutes - calendarInterruptDurationStepMinutes))
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 28, height: 32)
            }
            .buttonStyle(.plain)
            .disabled(durationMinutes <= calendarInterruptDurationStepMinutes)
            .opacity(durationMinutes <= calendarInterruptDurationStepMinutes ? 0.35 : 1)

            Text("\(durationMinutes)m")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let base = dragBaseDuration ?? durationMinutes
                            if dragBaseDuration == nil {
                                dragBaseDuration = durationMinutes
                            }
                            updateDuration(
                                calendarInterruptDurationFromScrub(
                                    baseMinutes: base,
                                    translationX: value.translation.width
                                )
                            )
                        }
                        .onEnded { _ in
                            dragBaseDuration = nil
                        }
                )

            Button {
                updateDuration(durationMinutes + calendarInterruptDurationStepMinutes)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 28, height: 32)
            }
            .buttonStyle(.plain)
        }
        .background(Color.secondary.opacity(0.08), in: Capsule())
    }

    private func updateDuration(_ newValue: Int) {
        let resolved = max(calendarInterruptDurationStepMinutes, newValue)
        guard resolved != durationMinutes else { return }
        durationMinutes = resolved
        if resolved != lastScrubDuration {
            impactFeedback.impactOccurred()
            impactFeedback.prepare()
            lastScrubDuration = resolved
        }
    }

    private func menuPosition(
        anchor: CGPoint,
        menuSize: CGSize,
        containerSize: CGSize,
        bottomInset: CGFloat = 0
    ) -> CGPoint {
        let margin: CGFloat = 12
        let bottomMargin = margin + bottomInset
        var x = anchor.x - menuSize.width / 2
        var y = anchor.y + 12

        x = max(margin, min(x, containerSize.width - menuSize.width - margin))
        if y + menuSize.height > containerSize.height - bottomMargin {
            y = anchor.y - menuSize.height - 12
        }
        y = max(margin, min(y, containerSize.height - menuSize.height - bottomMargin))
        return CGPoint(x: x, y: y)
    }

    private static var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        if AppTimeFormat.current.is24 {
            formatter.dateFormat = "H:mm"
        } else {
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "h:mm a"
            formatter.amSymbol = "am"
            formatter.pmSymbol = "pm"
        }
        return formatter
    }
}

struct CalendarInterruptLiveSession: Identifiable, Equatable {
    let id = UUID()
    let parentOccurrence: CalendarEventOccurrenceContext
    let parentEventID: UUID
    let parentEventSnapshot: Event
    let title: String
    let typeTitle: String
    let startedAt: Date
}

struct CalendarInterruptLiveBar: View {
    let session: CalendarInterruptLiveSession
    let onStop: () -> Void
    let onCancel: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 10) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(Self.elapsedFormatter.string(from: context.date.timeIntervalSince(session.startedAt)) ?? "0:00")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 30, height: 30)
                        .background(Color.secondary.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)

                Button {
                    onStop()
                } label: {
                    Text(L(.stopLabel))
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background(Color.primary.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.001), in: Capsule())
            .glassEffect(.regular, in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 6)
        }
    }

    private static let elapsedFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = [.pad]
        return formatter
    }()
}
