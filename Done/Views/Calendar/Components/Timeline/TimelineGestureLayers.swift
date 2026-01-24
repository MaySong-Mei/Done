//
//  TimelineGestureLayers.swift
//  Done
//
//  Gesture overlays for timeline edit/preview modes.
//

import SwiftUI

struct TimelineEditGestureLayerDay: View {
    let occurrences: [CalendarLayout.EventOccurrence]
    @Binding var selectedDayOffset: Int
    let dayRange: ClosedRange<Int>
    let size: CGSize
    let labelWidth: CGFloat
    let timelineTopInset: CGFloat
    let hourHeight: CGFloat
    let headerHeight: CGFloat
    let eventHorizontalInset: CGFloat
    let isActive: Bool
    var config: TimelineGestureConfig = .init()

    @EnvironmentObject private var store: EventStore
    @State private var interaction = TimelineInteractionState()
    @StateObject private var autoScroll = TimelineAutoScrollController()

    var body: some View {
        ZStack(alignment: .topLeading) {
            previewOverlay

            UIKitDragGestureView(
                minimumPressDuration: config.longPressDuration,
                shouldBegin: { true },
            onTap: {},
            onPanBegan: {},
            onPanChanged: { _ in },
            onPanEnded: { _, _ in },
            onPanBeganLocation: handleBegin(location:),
            onPanChangedLocation: handleChange(location:),
            onPanEndedLocation: handleEnd(location:),
            requiresScrollFailure: false,
            allowableMovement: 12,
            attachToScrollView: true,
            allowsSimultaneous: false,
            disableScrollWhileActive: true,
            isEnabled: isActive
        )
            .frame(width: size.width, height: size.height)
        }
        .onDisappear {
            autoScroll.stop()
        }
    }

    private var previewOverlay: some View {
        ZStack(alignment: .topLeading) {
            if let pickup = interaction.pickup {
                eventPreview(
                    range: pickup.currentRange,
                    dayOffset: pickup.currentDayOffset,
                    color: previewColor(for: pickup.eventID)
                )
            }
            if let draft = interaction.draft {
                eventPreview(
                    range: TimelineInteractions.normalizedRange(
                        start: draft.start,
                        end: draft.end,
                        minDurationMinutes: config.minDurationMinutes,
                        snapMinutes: config.snapMinutes
                    ),
                    dayOffset: draft.dayOffset,
                    color: Color.accentColor.opacity(0.25)
                )
            }
        }
        .allowsHitTesting(false)
    }

    private func handleBegin(location: CGPoint) {
        guard location.y >= timelineTopInset else { return }
        let day = date(for: selectedDayOffset)
        let contentWidth = max(0, size.width - labelWidth)

        if let hit = hitTestEvent(
            in: occurrences,
            date: day,
            columnX: labelWidth,
            columnWidth: contentWidth,
            location: location
        ) {
            let grabOffset = grabOffsetMinutes(
                for: hit.range.start,
                day: day,
                locationY: location.y
            )
            interaction.pickup = TimelinePickupState(
                eventID: hit.event.id,
                originalRange: hit.range,
                grabOffsetMinutes: grabOffset,
                currentRange: hit.range,
                currentDayOffset: selectedDayOffset
            )
            interaction.draft = nil
            return
        }

        guard let start = TimelineInteractions.snappedDate(
            at: location.y,
            day: day,
            timelineTopInset: timelineTopInset,
            headerHeight: headerHeight,
            hourHeight: hourHeight,
            snapMinutes: config.snapMinutes
        ) else { return }

        interaction.draft = TimelineDraftState(
            dayOffset: selectedDayOffset,
            start: start,
            end: start
        )
        interaction.pickup = nil
    }

    private func handleChange(location: CGPoint) {
        guard interaction.isActive else { return }
        updateAutoScroll(for: location.x)

        if var pickup = interaction.pickup {
            let day = date(for: selectedDayOffset)
            guard let snapped = TimelineInteractions.snappedDate(
                at: location.y,
                day: day,
                timelineTopInset: timelineTopInset,
                headerHeight: headerHeight,
                hourHeight: hourHeight,
                snapMinutes: config.snapMinutes
            ) else { return }

            let durationMinutes = Int(pickup.originalRange.end.timeIntervalSince(pickup.originalRange.start) / 60)
            var newStart = TimelineInteractions.date(byAddingMinutes: -pickup.grabOffsetMinutes, to: snapped)
            var newEnd = TimelineInteractions.date(byAddingMinutes: durationMinutes, to: newStart)

            clampRangeToDay(day: day, start: &newStart, end: &newEnd)

            pickup.currentRange = Event.TimeRange(start: newStart, end: newEnd)
            pickup.currentDayOffset = selectedDayOffset
            interaction.pickup = pickup
        } else if var draft = interaction.draft {
            let day = date(for: selectedDayOffset)
            guard let snapped = TimelineInteractions.snappedDate(
                at: location.y,
                day: day,
                timelineTopInset: timelineTopInset,
                headerHeight: headerHeight,
                hourHeight: hourHeight,
                snapMinutes: config.snapMinutes
            ) else { return }
            if draft.dayOffset != selectedDayOffset {
                draft.start = TimelineInteractions.combine(day: day, time: draft.start)
            }
            draft.dayOffset = selectedDayOffset
            draft.end = snapped
            interaction.draft = draft
        }
    }

    private func handleEnd(location: CGPoint) {
        autoScroll.stop()

        if let pickup = interaction.pickup {
            if let event = store.events.first(where: { $0.id == pickup.eventID }) {
                let updated = TimelineInteractions.updateEvent(
                    event,
                    replacing: pickup.originalRange,
                    with: pickup.currentRange
                )
                store.update(updated)
            }
        } else if let draft = interaction.draft {
            let range = TimelineInteractions.normalizedRange(
                start: draft.start,
                end: draft.end,
                minDurationMinutes: config.minDurationMinutes,
                snapMinutes: config.snapMinutes
            )
            let newEvent = Event(
                title: "New Event",
                note: "",
                startTime: range.start,
                endTime: range.end,
                timeRanges: [range],
                deadline: nil,
                repeatUnit: .none,
                isDone: false,
                repeatInterval: 1,
                repeatEndType: .none,
                repeatEndDate: nil,
                repeatEndCount: nil,
                gridWidth: 8,
                gridHeight: 8,
                priority: 0,
                tags: [],
                type: "Study"
            )
            store.addWithAutoPlacement(newEvent)
        }

        interaction = TimelineInteractionState()
    }

    private func updateAutoScroll(for locationX: CGFloat) {
        let leftEdge = labelWidth + config.autoScrollEdgePadding
        let rightEdge = size.width - config.autoScrollEdgePadding
        let direction: Int
        if locationX < leftEdge {
            direction = -1
        } else if locationX > rightEdge {
            direction = 1
        } else {
            direction = 0
        }

        autoScroll.start(direction: direction, interval: config.autoScrollInterval, step: config.autoScrollStepDays) { delta in
            let next = clampSelectedDayOffset(selectedDayOffset + delta)
            if next == selectedDayOffset {
                autoScroll.stop()
            } else {
                selectedDayOffset = next
            }
        }
    }

    private func clampSelectedDayOffset(_ value: Int) -> Int {
        min(max(value, dayRange.lowerBound), dayRange.upperBound)
    }

    private func date(for offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
    }

    private func grabOffsetMinutes(for start: Date, day: Date, locationY: CGFloat) -> Int {
        let dayStart = Calendar.current.startOfDay(for: day)
        let startMinutes = Int(start.timeIntervalSince(dayStart) / 60)
        let locationMinutes = minutesFromLocationY(locationY, day: day)
        return max(0, locationMinutes - startMinutes)
    }

    private func minutesFromLocationY(_ locationY: CGFloat, day: Date) -> Int {
        let y = max(0, locationY - timelineTopInset - headerHeight)
        let minutes = Int((y / hourHeight) * 60)
        return max(0, min(24 * 60, minutes))
    }

    private func clampRangeToDay(day: Date, start: inout Date, end: inout Date) {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let duration = end.timeIntervalSince(start)
        if end > dayEnd {
            end = dayEnd
            start = end.addingTimeInterval(-duration)
        }
        if start < dayStart {
            start = dayStart
            end = start.addingTimeInterval(duration)
        }
    }

    private func hitTestEvent(
        in occurrences: [CalendarLayout.EventOccurrence],
        date: Date,
        columnX: CGFloat,
        columnWidth: CGFloat,
        location: CGPoint
    ) -> CalendarLayout.EventOccurrence? {
        for occurrence in occurrences {
            let frame = TimelineInteractions.eventFrame(
                occurrence: occurrence,
                date: date,
                columnX: columnX,
                columnWidth: columnWidth,
                timelineTopInset: timelineTopInset,
                headerHeight: headerHeight,
                hourHeight: hourHeight,
                horizontalInset: eventHorizontalInset
            )
            if frame.contains(location) {
                return occurrence
            }
        }
        return nil
    }

    private func eventPreview(range: Event.TimeRange, dayOffset: Int, color: Color) -> some View {
        let day = date(for: dayOffset)
        let contentWidth = max(0, size.width - labelWidth)
        let frame = TimelineInteractions.eventFrame(
            occurrence: CalendarLayout.EventOccurrence(
                id: "\(dayOffset)-preview-\(range.start.timeIntervalSince1970)",
                event: Event(title: "Preview"),
                range: range
            ),
            date: day,
            columnX: labelWidth,
            columnWidth: contentWidth,
            timelineTopInset: timelineTopInset,
            headerHeight: headerHeight,
            hourHeight: hourHeight,
            horizontalInset: eventHorizontalInset
        )
        return RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(color)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(color.opacity(0.6), lineWidth: 1)
            )
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
    }

    private func previewColor(for eventID: UUID) -> Color {
        if let event = store.events.first(where: { $0.id == eventID }) {
            return CalendarLayout.eventColor(for: event).opacity(0.25)
        }
        return Color.accentColor.opacity(0.25)
    }
}

struct TimelineEditGestureLayerMultiDay: View {
    let occurrencesForOffset: (Int) -> [CalendarLayout.EventOccurrence]
    @Binding var selectedDayOffset: Int
    let dayRange: ClosedRange<Int>
    let daysCount: Int
    let size: CGSize
    let labelWidth: CGFloat
    let dayWidth: CGFloat
    let daySpacing: CGFloat
    let timelineTopInset: CGFloat
    let hourHeight: CGFloat
    let headerHeight: CGFloat
    let eventHorizontalInset: CGFloat
    let isActive: Bool
    var config: TimelineGestureConfig = .init()

    @EnvironmentObject private var store: EventStore
    @State private var interaction = TimelineInteractionState()
    @StateObject private var autoScroll = TimelineAutoScrollController()

    var body: some View {
        ZStack(alignment: .topLeading) {
            previewOverlay

            UIKitDragGestureView(
                minimumPressDuration: config.longPressDuration,
                shouldBegin: { true },
            onTap: {},
            onPanBegan: {},
            onPanChanged: { _ in },
            onPanEnded: { _, _ in },
            onPanBeganLocation: handleBegin(location:),
            onPanChangedLocation: handleChange(location:),
            onPanEndedLocation: handleEnd(location:),
            requiresScrollFailure: false,
            allowableMovement: 12,
            attachToScrollView: true,
            allowsSimultaneous: false,
            disableScrollWhileActive: true,
            isEnabled: isActive
        )
            .frame(width: size.width, height: size.height)
        }
        .onDisappear {
            autoScroll.stop()
        }
    }

    private var previewOverlay: some View {
        ZStack(alignment: .topLeading) {
            if let pickup = interaction.pickup {
                eventPreview(
                    range: pickup.currentRange,
                    dayOffset: pickup.currentDayOffset,
                    color: previewColor(for: pickup.eventID)
                )
            }
            if let draft = interaction.draft {
                eventPreview(
                    range: TimelineInteractions.normalizedRange(
                        start: draft.start,
                        end: draft.end,
                        minDurationMinutes: config.minDurationMinutes,
                        snapMinutes: config.snapMinutes
                    ),
                    dayOffset: draft.dayOffset,
                    color: Color.accentColor.opacity(0.25)
                )
            }
        }
        .allowsHitTesting(false)
    }

    private func handleBegin(location: CGPoint) {
        guard location.y >= timelineTopInset else { return }
        guard let dayOffset = dayOffset(for: location.x) else { return }
        let day = date(for: dayOffset)

        if let hit = hitTestEvent(
            for: dayOffset,
            day: day,
            location: location
        ) {
            let grabOffset = grabOffsetMinutes(
                for: hit.range.start,
                day: day,
                locationY: location.y
            )
            interaction.pickup = TimelinePickupState(
                eventID: hit.event.id,
                originalRange: hit.range,
                grabOffsetMinutes: grabOffset,
                currentRange: hit.range,
                currentDayOffset: dayOffset
            )
            interaction.draft = nil
            return
        }

        guard let start = TimelineInteractions.snappedDate(
            at: location.y,
            day: day,
            timelineTopInset: timelineTopInset,
            headerHeight: headerHeight,
            hourHeight: hourHeight,
            snapMinutes: config.snapMinutes
        ) else { return }

        interaction.draft = TimelineDraftState(
            dayOffset: dayOffset,
            start: start,
            end: start
        )
        interaction.pickup = nil
    }

    private func handleChange(location: CGPoint) {
        guard interaction.isActive else { return }
        updateAutoScroll(for: location.x)

        guard let dayOffset = dayOffset(for: location.x) else { return }
        let day = date(for: dayOffset)

        if var pickup = interaction.pickup {
            guard let snapped = TimelineInteractions.snappedDate(
                at: location.y,
                day: day,
                timelineTopInset: timelineTopInset,
                headerHeight: headerHeight,
                hourHeight: hourHeight,
                snapMinutes: config.snapMinutes
            ) else { return }

            let durationMinutes = Int(pickup.originalRange.end.timeIntervalSince(pickup.originalRange.start) / 60)
            var newStart = TimelineInteractions.date(byAddingMinutes: -pickup.grabOffsetMinutes, to: snapped)
            var newEnd = TimelineInteractions.date(byAddingMinutes: durationMinutes, to: newStart)
            clampRangeToDay(day: day, start: &newStart, end: &newEnd)

            pickup.currentRange = Event.TimeRange(start: newStart, end: newEnd)
            pickup.currentDayOffset = dayOffset
            interaction.pickup = pickup
        } else if var draft = interaction.draft {
            guard let snapped = TimelineInteractions.snappedDate(
                at: location.y,
                day: day,
                timelineTopInset: timelineTopInset,
                headerHeight: headerHeight,
                hourHeight: hourHeight,
                snapMinutes: config.snapMinutes
            ) else { return }
            if draft.dayOffset != dayOffset {
                draft.start = TimelineInteractions.combine(day: day, time: draft.start)
            }
            draft.dayOffset = dayOffset
            draft.end = snapped
            interaction.draft = draft
        }
    }

    private func handleEnd(location: CGPoint) {
        autoScroll.stop()

        if let pickup = interaction.pickup {
            if let event = store.events.first(where: { $0.id == pickup.eventID }) {
                let updated = TimelineInteractions.updateEvent(
                    event,
                    replacing: pickup.originalRange,
                    with: pickup.currentRange
                )
                store.update(updated)
            }
        } else if let draft = interaction.draft {
            let range = TimelineInteractions.normalizedRange(
                start: draft.start,
                end: draft.end,
                minDurationMinutes: config.minDurationMinutes,
                snapMinutes: config.snapMinutes
            )
            let newEvent = Event(
                title: "New Event",
                note: "",
                startTime: range.start,
                endTime: range.end,
                timeRanges: [range],
                deadline: nil,
                repeatUnit: .none,
                isDone: false,
                repeatInterval: 1,
                repeatEndType: .none,
                repeatEndDate: nil,
                repeatEndCount: nil,
                gridWidth: 8,
                gridHeight: 8,
                priority: 0,
                tags: [],
                type: "Study"
            )
            store.addWithAutoPlacement(newEvent)
        }

        interaction = TimelineInteractionState()
    }

    private func updateAutoScroll(for locationX: CGFloat) {
        let leftEdge = labelWidth + config.autoScrollEdgePadding
        let rightEdge = labelWidth + daysAreaWidth - config.autoScrollEdgePadding
        let direction: Int
        if locationX < leftEdge {
            direction = -1
        } else if locationX > rightEdge {
            direction = 1
        } else {
            direction = 0
        }

        autoScroll.start(direction: direction, interval: config.autoScrollInterval, step: config.autoScrollStepDays) { delta in
            let next = clampLeadingOffset(selectedDayOffset + delta)
            if next == selectedDayOffset {
                autoScroll.stop()
            } else {
                selectedDayOffset = next
            }
        }
    }

    private var daysAreaWidth: CGFloat {
        max(0, size.width - labelWidth)
    }

    private func clampLeadingOffset(_ value: Int) -> Int {
        let leadingRange = leadingOffsetsRange()
        return min(max(value, leadingRange.lowerBound), leadingRange.upperBound)
    }

    private func leadingOffsetsRange() -> ClosedRange<Int> {
        let lower = dayRange.lowerBound
        let upper = dayRange.upperBound - (daysCount - 1)
        if lower <= upper {
            return lower...upper
        }
        return lower...lower
    }

    private func dayOffset(for locationX: CGFloat) -> Int? {
        let localX = locationX - labelWidth
        guard localX >= 0, dayWidth > 0 else { return nil }
        let step = dayWidth + daySpacing
        let index = Int(floor(localX / step))
        guard index >= 0, index < daysCount else { return nil }
        return selectedDayOffset + index
    }

    private func date(for offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
    }

    private func grabOffsetMinutes(for start: Date, day: Date, locationY: CGFloat) -> Int {
        let dayStart = Calendar.current.startOfDay(for: day)
        let startMinutes = Int(start.timeIntervalSince(dayStart) / 60)
        let locationMinutes = minutesFromLocationY(locationY)
        return max(0, locationMinutes - startMinutes)
    }

    private func minutesFromLocationY(_ locationY: CGFloat) -> Int {
        let y = max(0, locationY - timelineTopInset - headerHeight)
        let minutes = Int((y / hourHeight) * 60)
        return max(0, min(24 * 60, minutes))
    }

    private func clampRangeToDay(day: Date, start: inout Date, end: inout Date) {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let duration = end.timeIntervalSince(start)
        if end > dayEnd {
            end = dayEnd
            start = end.addingTimeInterval(-duration)
        }
        if start < dayStart {
            start = dayStart
            end = start.addingTimeInterval(duration)
        }
    }

    private func hitTestEvent(
        for dayOffset: Int,
        day: Date,
        location: CGPoint
    ) -> CalendarLayout.EventOccurrence? {
        let occurrences = occurrencesForOffset(dayOffset)
        let columnX = labelWidth + CGFloat(dayOffset - selectedDayOffset) * (dayWidth + daySpacing)
        for occurrence in occurrences {
            let frame = TimelineInteractions.eventFrame(
                occurrence: occurrence,
                date: day,
                columnX: columnX,
                columnWidth: dayWidth,
                timelineTopInset: timelineTopInset,
                headerHeight: headerHeight,
                hourHeight: hourHeight,
                horizontalInset: eventHorizontalInset
            )
            if frame.contains(location) {
                return occurrence
            }
        }
        return nil
    }

    private func eventPreview(range: Event.TimeRange, dayOffset: Int, color: Color) -> some View {
        let day = date(for: dayOffset)
        let columnX = labelWidth + CGFloat(dayOffset - selectedDayOffset) * (dayWidth + daySpacing)
        let frame = TimelineInteractions.eventFrame(
            occurrence: CalendarLayout.EventOccurrence(
                id: "\(dayOffset)-preview-\(range.start.timeIntervalSince1970)",
                event: Event(title: "Preview"),
                range: range
            ),
            date: day,
            columnX: columnX,
            columnWidth: dayWidth,
            timelineTopInset: timelineTopInset,
            headerHeight: headerHeight,
            hourHeight: hourHeight,
            horizontalInset: eventHorizontalInset
        )
        return RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(color)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(color.opacity(0.6), lineWidth: 1)
            )
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
    }

    private func previewColor(for eventID: UUID) -> Color {
        if let event = store.events.first(where: { $0.id == eventID }) {
            return CalendarLayout.eventColor(for: event).opacity(0.25)
        }
        return Color.accentColor.opacity(0.25)
    }
}

struct TimelinePreviewGestureLayerDay: View {
    let occurrences: [CalendarLayout.EventOccurrence]
    let size: CGSize
    let labelWidth: CGFloat
    let timelineTopInset: CGFloat
    let hourHeight: CGFloat
    let headerHeight: CGFloat
    let eventHorizontalInset: CGFloat
    let dayOffset: Int
    let isActive: Bool
    var config: TimelineGestureConfig = .init()
    let onPreviewEvent: (Event) -> Void

    var body: some View {
        UIKitDragGestureView(
            minimumPressDuration: config.longPressDuration,
            shouldBegin: { true },
            onTap: {},
            onPanBegan: {},
            onPanChanged: { _ in },
            onPanEnded: { _, _ in },
            onPanBeganLocation: handleBegin(location:),
            requiresScrollFailure: false,
            allowableMovement: 12,
            attachToScrollView: true,
            allowsSimultaneous: true,
            isEnabled: isActive
        )
        .frame(width: size.width, height: size.height)
    }

    private func handleBegin(location: CGPoint) {
        guard location.y >= timelineTopInset else { return }
        let day = date(for: dayOffset)
        let contentWidth = max(0, size.width - labelWidth)
        for occurrence in occurrences {
            let frame = TimelineInteractions.eventFrame(
                occurrence: occurrence,
                date: day,
                columnX: labelWidth,
                columnWidth: contentWidth,
                timelineTopInset: timelineTopInset,
                headerHeight: headerHeight,
                hourHeight: hourHeight,
                horizontalInset: eventHorizontalInset
            )
            if frame.contains(location) {
                onPreviewEvent(occurrence.event)
                break
            }
        }
    }

    private func date(for offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
    }
}

struct TimelinePreviewGestureLayerMultiDay: View {
    let occurrencesForOffset: (Int) -> [CalendarLayout.EventOccurrence]
    let selectedDayOffset: Int
    let daysCount: Int
    let size: CGSize
    let labelWidth: CGFloat
    let dayWidth: CGFloat
    let daySpacing: CGFloat
    let timelineTopInset: CGFloat
    let hourHeight: CGFloat
    let headerHeight: CGFloat
    let eventHorizontalInset: CGFloat
    let isActive: Bool
    var config: TimelineGestureConfig = .init()
    let onPreviewEvent: (Event) -> Void

    var body: some View {
        UIKitDragGestureView(
            minimumPressDuration: config.longPressDuration,
            shouldBegin: { true },
            onTap: {},
            onPanBegan: {},
            onPanChanged: { _ in },
            onPanEnded: { _, _ in },
            onPanBeganLocation: handleBegin(location:),
            requiresScrollFailure: false,
            allowableMovement: 12,
            attachToScrollView: true,
            allowsSimultaneous: true,
            isEnabled: isActive
        )
        .frame(width: size.width, height: size.height)
    }

    private func handleBegin(location: CGPoint) {
        guard location.y >= timelineTopInset else { return }
        guard let dayOffset = dayOffset(for: location.x) else { return }
        let day = date(for: dayOffset)
        let columnX = labelWidth + CGFloat(dayOffset - selectedDayOffset) * (dayWidth + daySpacing)
        let occurrences = occurrencesForOffset(dayOffset)
        for occurrence in occurrences {
            let frame = TimelineInteractions.eventFrame(
                occurrence: occurrence,
                date: day,
                columnX: columnX,
                columnWidth: dayWidth,
                timelineTopInset: timelineTopInset,
                headerHeight: headerHeight,
                hourHeight: hourHeight,
                horizontalInset: eventHorizontalInset
            )
            if frame.contains(location) {
                onPreviewEvent(occurrence.event)
                break
            }
        }
    }

    private func dayOffset(for locationX: CGFloat) -> Int? {
        let localX = locationX - labelWidth
        guard localX >= 0, dayWidth > 0 else { return nil }
        let step = dayWidth + daySpacing
        let index = Int(floor(localX / step))
        guard index >= 0, index < daysCount else { return nil }
        return selectedDayOffset + index
    }

    private func date(for offset: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
    }
}
