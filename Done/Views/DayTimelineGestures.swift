//
//  DayTimelineGestures.swift
//  Done
//
//  Gesture helpers extracted from DayTimelineView.swift
//

import SwiftUI

// MARK: - DayTimelineView Gestures
extension DayTimelineView {
    func handleMagnificationGesture(_ value: CGFloat) {
        withAnimation(.easeInOut(duration: 0.25)) {
            let currentLeading = leadingDate ?? startOfDay(selectedDate)
            let oldDayCount = dayCount
            let oldCenterOffset = oldDayCount / 2
            let currentCenter = Calendar.current.date(byAdding: .day, value: oldCenterOffset, to: currentLeading) ?? currentLeading

            if value < 0.95 {
                switch viewMode {
                case .day:
                    viewMode = .threeDays
                case .threeDays:
                    viewMode = .week
                case .week:
                    print("Already at Week view")
                }
            } else if value > 1.05 {
                switch viewMode {
                case .week:
                    viewMode = .threeDays
                case .threeDays:
                    viewMode = .day
                case .day:
                    print("Already at Day view")
                }
            } else {
                print("No change")
            }

            let newDayCount = viewMode.rawValue
            let newCenterOffset = newDayCount / 2
            let newLeading = Calendar.current.date(byAdding: .day, value: -newCenterOffset, to: currentCenter) ?? currentCenter
            leadingDate = nil
            DispatchQueue.main.async {
                leadingDate = startOfDay(newLeading)
            }
            selectedDate = currentCenter
        }
    }
}

// MARK: - DayColumn Gestures
extension DayColumn {
    var createDraftGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.2, maximumDistance: 8)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onEnded { value in
                guard case .second(true, let drag?) = value else { return }
                createDraft(at: drag.location)
            }
    }

    func createDraft(at location: CGPoint) {
        let slices = slicesForDay()
        let y = min(max(0, location.y), geometry.totalHeight)
        let time = timeForY(y)
        let isOccupied = slices.contains { time >= $0.start && time < $0.end }
        guard !isOccupied else { return }

        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: date)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) ?? date
        let end = min(time.addingTimeInterval(3600), dayEnd)

        draftEntry = TimeEntry(
            id: UUID(),
            templateId: UUID(),
            templateName: "New",
            startTime: time,
            endTime: end,
            colorHex: "#4A4A4A",
            syncedToCalendar: false,
            calendarEventId: nil
        )
    }

    func timeForY(_ y: CGFloat) -> Date {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: date)
        let seconds = TimeInterval((y / geometry.hourHeight) * 3600)
        let clamped = min(max(0, seconds), 24 * 3600 - 1)
        return dayStart.addingTimeInterval(clamped)
    }
}

// MARK: - TimelineEventBlock Gestures
extension TimelineEventBlock {
    var dragGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .updating($isDragging) { _, state, _ in
                guard style == .completed, dragArmed else { return }
                state = true
            }
            .updating($dragTranslation) { value, state, _ in
                guard style == .completed, dragArmed else { return }
                if abs(value.translation.height) > abs(value.translation.width) {
                    state = value.translation
                }
            }
            .onEnded { value in
                guard style == .completed, dragArmed else { return }
                dragArmed = false
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                guard let endTime = entry.endTime else { return }

                let hoursDelta = value.translation.height / geometry.hourHeight
                let timeDelta = TimeInterval(hoursDelta * 3600)
                let updatedEntry = TimeEntry(
                    id: entry.id,
                    templateId: entry.templateId,
                    templateName: entry.templateName,
                    startTime: entry.startTime.addingTimeInterval(timeDelta),
                    endTime: endTime.addingTimeInterval(timeDelta),
                    colorHex: entry.colorHex,
                    syncedToCalendar: entry.syncedToCalendar,
                    calendarEventId: entry.calendarEventId
                )
                dataManager.updateTimeEntry(updatedEntry)
            }
    }

    @ViewBuilder
    func resizeHandles(height: CGFloat) -> some View {
        if isDraft {
            VStack(spacing: 0) {
                resizeHandle
                    .contentShape(Rectangle())
                    .gesture(resizeTopGesture)

                Spacer(minLength: 0)

                resizeHandle
                    .contentShape(Rectangle())
                    .gesture(resizeBottomGesture)
            }
            .frame(maxWidth: .infinity, maxHeight: height)
        }
    }

    var resizeHandle: some View {
        Capsule()
            .fill(Color.white.opacity(0.75))
            .frame(height: 6)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
    }

    var resizeTopGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($resizeTopOffset) { value, state, _ in
                state = value.translation.height
            }
            .onEnded { value in
                commitDraftResize(topOffset: value.translation.height, bottomOffset: 0)
            }
    }

    var resizeBottomGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($resizeBottomOffset) { value, state, _ in
                state = value.translation.height
            }
            .onEnded { value in
                commitDraftResize(topOffset: 0, bottomOffset: value.translation.height)
            }
    }

    func draftAdjustedTimes() -> (Date, Date) {
        guard isDraft else { return (renderStart, renderEnd) }
        let minDuration: TimeInterval = 300
        let dayStart = Calendar.current.startOfDay(for: renderStart)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? renderEnd

        let topSeconds = TimeInterval((resizeTopOffset / geometry.hourHeight) * 3600)
        let bottomSeconds = TimeInterval((resizeBottomOffset / geometry.hourHeight) * 3600)
        var proposedStart = renderStart.addingTimeInterval(topSeconds)
        var proposedEnd = renderEnd.addingTimeInterval(bottomSeconds)

        proposedStart = max(proposedStart, dayStart)
        proposedEnd = min(proposedEnd, dayEnd)

        if proposedEnd.timeIntervalSince(proposedStart) < minDuration {
            if resizeTopOffset != 0 {
                proposedStart = proposedEnd.addingTimeInterval(-minDuration)
            } else if resizeBottomOffset != 0 {
                proposedEnd = proposedStart.addingTimeInterval(minDuration)
            }
        }
        return (proposedStart, proposedEnd)
    }

    func commitDraftResize(topOffset: CGFloat, bottomOffset: CGFloat) {
        guard isDraft, var draft = draftEntry, draft.id == entry.id else { return }
        let minDuration: TimeInterval = 300
        let dayStart = Calendar.current.startOfDay(for: renderStart)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? renderEnd

        let topSeconds = TimeInterval((topOffset / geometry.hourHeight) * 3600)
        let bottomSeconds = TimeInterval((bottomOffset / geometry.hourHeight) * 3600)
        var newStart = renderStart.addingTimeInterval(topSeconds)
        var newEnd = renderEnd.addingTimeInterval(bottomSeconds)

        newStart = max(newStart, dayStart)
        newEnd = min(newEnd, dayEnd)

        if newEnd.timeIntervalSince(newStart) < minDuration {
            if topOffset != 0 {
                newStart = newEnd.addingTimeInterval(-minDuration)
            } else if bottomOffset != 0 {
                newEnd = newStart.addingTimeInterval(minDuration)
            }
        }

        draft.startTime = newStart
        draft.endTime = newEnd
        draftEntry = draft
    }
}
