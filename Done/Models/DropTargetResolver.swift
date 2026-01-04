//
//  DropTargetResolver.swift
//  Done
//
//  Created by Codex on 3/10/26.
//

import CoreGraphics
import Foundation

struct DropTarget: Equatable {
    let targetDate: Date
    let snappedStartTime: Date
    let dayIndex: Int
}

struct DropTargetGeometry {
    let hourHeight: CGFloat
    let timeAxisWidth: CGFloat
    let scrollViewOrigin: CGPoint
}

@MainActor
enum DropTargetResolver {
    static let snapIntervalMinutes: Int = 15
    private static let columnHysteresisFraction: CGFloat = 0.2

    static func resolve(
        ghostScreenPoint: CGPoint,
        viewportState: ViewportState,
        timelineGeometry: DropTargetGeometry,
        renderDates: [Date],
        columnWidth: CGFloat,
        currentDayIndex: Int? = nil
    ) -> DropTarget? {
        guard columnWidth > 0, !renderDates.isEmpty else { return nil }

        let localX = ghostScreenPoint.x - timelineGeometry.scrollViewOrigin.x
        let localY = ghostScreenPoint.y - timelineGeometry.scrollViewOrigin.y
        let contentX = localX - timelineGeometry.timeAxisWidth - viewportState.horizontalOffset
        let contentY = localY - viewportState.verticalOffset

        var resolvedDayIndex = Int(contentX / columnWidth)
        resolvedDayIndex = min(max(0, resolvedDayIndex), renderDates.count - 1)

        if let currentDayIndex,
           currentDayIndex >= 0,
           currentDayIndex < renderDates.count {
            let currentMinX = CGFloat(currentDayIndex) * columnWidth
            let currentMaxX = currentMinX + columnWidth
            let hysteresis = columnWidth * columnHysteresisFraction
            if contentX >= currentMinX - hysteresis && contentX <= currentMaxX + hysteresis {
                resolvedDayIndex = currentDayIndex
            }
        }

        let maxContentY = timelineGeometry.hourHeight * 24
        let clampedContentY = min(max(0, contentY), maxContentY)
        let rawMinutes = clampedContentY / timelineGeometry.hourHeight * 60
        let snappedMinutes = Int(
            (rawMinutes / CGFloat(snapIntervalMinutes)).rounded() * CGFloat(snapIntervalMinutes)
        )
        let maxSnappableMinutes = 24 * 60 - snapIntervalMinutes
        let clampedMinutes = min(max(0, snappedMinutes), maxSnappableMinutes)

        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: renderDates[resolvedDayIndex])
        let snappedStartTime = calendar.date(byAdding: .minute, value: clampedMinutes, to: dayStart) ?? dayStart

        return DropTarget(
            targetDate: dayStart,
            snappedStartTime: snappedStartTime,
            dayIndex: resolvedDayIndex
        )
    }
}
