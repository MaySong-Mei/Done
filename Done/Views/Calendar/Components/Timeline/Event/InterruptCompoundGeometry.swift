//
//  InterruptCompoundGeometry.swift
//  Done
//
//  The interrupt family's geometry: where an embedded interrupt child sits
//  on its parent's column, and the parent's compound silhouette with a moat
//  cut around each child. Pure CoreGraphics/SwiftUI, shared by the phone's
//  renderer and the Mac's (moved verbatim from EventBlock.swift).
//

import SwiftUI

struct CalendarInterruptOverlayGeometry: Equatable {
    let width: CGFloat
    let xOffset: CGFloat
}

func calendarInterruptOverlayGeometry(parentWidth: CGFloat) -> CalendarInterruptOverlayGeometry {
    guard parentWidth > 0 else {
        return CalendarInterruptOverlayGeometry(width: 0, xOffset: 0)
    }
    let leadingInset: CGFloat = 8
    let width = max(0, parentWidth - leadingInset)
    let xOffset = min(leadingInset, parentWidth)
    return CalendarInterruptOverlayGeometry(width: width, xOffset: xOffset)
}

func calendarInterruptChildOverlayGeometry(parentWidth: CGFloat) -> CalendarInterruptOverlayGeometry {
    calendarInterruptOverlayGeometry(parentWidth: parentWidth)
}

func calendarInterruptCutoutGeometry(
    parentWidth: CGFloat,
    moatWidth: CGFloat
) -> CalendarInterruptOverlayGeometry {
    let childOverlay = calendarInterruptChildOverlayGeometry(parentWidth: parentWidth)
    let xOffset = max(0, childOverlay.xOffset - moatWidth)
    return CalendarInterruptOverlayGeometry(
        width: max(0, parentWidth - xOffset),
        xOffset: xOffset
    )
}

struct CalendarInterruptCompoundCutoutGeometry: Equatable {
    let rect: CGRect
    let hasTopLobe: Bool
    let hasBottomLobe: Bool
}

struct CalendarInterruptParentVisibleSegment: Equatable {
    let yStart: CGFloat
    let yEnd: CGFloat
    let width: CGFloat
}

struct CalendarInterruptParentCompoundGeometry: Equatable {
    let cutouts: [CalendarInterruptCompoundCutoutGeometry]
    let spineRect: CGRect
    let visibleSegments: [CalendarInterruptParentVisibleSegment]
    let contentRects: [CGRect]

    var isStandaloneSpine: Bool {
        cutouts.count == 1 && !cutouts[0].hasTopLobe && !cutouts[0].hasBottomLobe
    }
}

func calendarInterruptMergedRanges(
    parentRange: Event.TimeRange,
    childRanges: [Event.TimeRange]
) -> [Event.TimeRange] {
    let clipped = childRanges.compactMap { childRange -> Event.TimeRange? in
        let start = max(parentRange.start, childRange.start)
        let end = min(parentRange.end, childRange.end)
        guard end > start else { return nil }
        return Event.TimeRange(start: start, end: end)
    }
    .sorted { lhs, rhs in
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        return lhs.end < rhs.end
    }

    guard !clipped.isEmpty else { return [] }
    var merged: [Event.TimeRange] = [clipped[0]]
    for range in clipped.dropFirst() {
        let lastIndex = merged.index(before: merged.endIndex)
        if range.start <= merged[lastIndex].end {
            merged[lastIndex].end = max(merged[lastIndex].end, range.end)
        } else {
            merged.append(range)
        }
    }
    return merged
}

func calendarInterruptParentCompoundGeometry(
    parentRange: Event.TimeRange,
    childRanges: [Event.TimeRange],
    parentWidth: CGFloat,
    parentHeight: CGFloat,
    horizontalGap: CGFloat,
    verticalGap: CGFloat
) -> CalendarInterruptParentCompoundGeometry {
    guard parentWidth > 0, parentHeight > 0 else {
        return CalendarInterruptParentCompoundGeometry(
            cutouts: [],
            spineRect: .zero,
            visibleSegments: [],
            contentRects: []
        )
    }

    let mergedRanges = calendarInterruptMergedRanges(
        parentRange: parentRange,
        childRanges: childRanges
    )
    let totalDuration = max(parentRange.end.timeIntervalSince(parentRange.start), 1)
    let cutoutGeometry = calendarInterruptCutoutGeometry(
        parentWidth: parentWidth,
        moatWidth: horizontalGap
    )

    let rawRects = mergedRanges.compactMap { range -> CGRect? in
        let topProgress = range.start.timeIntervalSince(parentRange.start) / totalDuration
        let segmentProgress = range.end.timeIntervalSince(range.start) / totalDuration
        let rawTop = parentHeight * CGFloat(topProgress) - verticalGap
        let top = max(0, rawTop)
        let rawHeight = parentHeight * CGFloat(segmentProgress) + verticalGap * 2
        let height = min(
            max(verticalGap * 2 + 2, rawHeight),
            max(0, parentHeight - top)
        )
        guard height > 0 else { return nil }
        return CGRect(
            x: cutoutGeometry.xOffset,
            y: top,
            width: cutoutGeometry.width,
            height: height
        )
    }
    .sorted { lhs, rhs in
        if lhs.minY != rhs.minY { return lhs.minY < rhs.minY }
        return lhs.maxY < rhs.maxY
    }

    let mergedRects: [CGRect] = rawRects.reduce(into: []) { partialResult, rect in
        guard let last = partialResult.last else {
            partialResult.append(rect)
            return
        }
        if rect.minY <= last.maxY {
            let mergedRect = CGRect(
                x: last.minX,
                y: last.minY,
                width: last.width,
                height: max(last.maxY, rect.maxY) - last.minY
            )
            partialResult[partialResult.count - 1] = mergedRect
        } else {
            partialResult.append(rect)
        }
    }

    let cutouts = mergedRects.map { rect in
        CalendarInterruptCompoundCutoutGeometry(
            rect: rect,
            hasTopLobe: rect.minY > 0.5,
            hasBottomLobe: rect.maxY < parentHeight - 0.5
        )
    }

    let fullWidth = parentWidth
    let spineWidth = max(0, cutoutGeometry.xOffset)
    var visibleSegments: [CalendarInterruptParentVisibleSegment] = []
    var currentY: CGFloat = 0

    for rect in mergedRects {
        if rect.minY > currentY + 0.5 {
            visibleSegments.append(
                CalendarInterruptParentVisibleSegment(
                    yStart: currentY,
                    yEnd: rect.minY,
                    width: fullWidth
                )
            )
        }
        if rect.maxY > rect.minY + 0.5 {
            visibleSegments.append(
                CalendarInterruptParentVisibleSegment(
                    yStart: rect.minY,
                    yEnd: rect.maxY,
                    width: spineWidth
                )
            )
        }
        currentY = rect.maxY
    }

    if currentY < parentHeight - 0.5 {
        visibleSegments.append(
            CalendarInterruptParentVisibleSegment(
                yStart: currentY,
                yEnd: parentHeight,
                width: fullWidth
            )
        )
    }

    if visibleSegments.isEmpty {
        visibleSegments = [
            CalendarInterruptParentVisibleSegment(
                yStart: 0,
                yEnd: parentHeight,
                width: fullWidth
            )
        ]
    }

    let normalizedVisibleSegments: [CalendarInterruptParentVisibleSegment] = visibleSegments.reduce(into: []) { partialResult, segment in
        guard segment.yEnd > segment.yStart else { return }
        guard let last = partialResult.last else {
            partialResult.append(segment)
            return
        }
        if abs(last.width - segment.width) < 0.5,
           abs(last.yEnd - segment.yStart) < 0.5 {
            partialResult[partialResult.count - 1] = CalendarInterruptParentVisibleSegment(
                yStart: last.yStart,
                yEnd: segment.yEnd,
                width: last.width
            )
        } else {
            partialResult.append(segment)
        }
    }

    let contentRects = normalizedVisibleSegments.map {
        CGRect(
            x: 0,
            y: $0.yStart,
            width: $0.width,
            height: $0.yEnd - $0.yStart
        )
    }

    return CalendarInterruptParentCompoundGeometry(
        cutouts: cutouts,
        spineRect: CGRect(
            x: 0,
            y: 0,
            width: max(0, cutoutGeometry.xOffset),
            height: parentHeight
        ),
        visibleSegments: normalizedVisibleSegments,
        contentRects: contentRects
    )
}

struct CalendarInterruptParentCompoundShape: Shape {
    let cornerRadius: CGFloat
    let visibleSegments: [CalendarInterruptParentVisibleSegment]

    func path(in rect: CGRect) -> Path {
        guard let firstSegment = visibleSegments.first else {
            return RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .path(in: rect)
        }

        var points: [CGPoint] = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.minX + firstSegment.width, y: rect.minY)
        ]

        for (index, segment) in visibleSegments.enumerated() {
            points.append(
                CGPoint(
                    x: rect.minX + segment.width,
                    y: rect.minY + segment.yEnd
                )
            )

            if index < visibleSegments.count - 1 {
                let next = visibleSegments[index + 1]
                if abs(next.width - segment.width) > 0.5 {
                    points.append(
                        CGPoint(
                            x: rect.minX + next.width,
                            y: rect.minY + segment.yEnd
                        )
                    )
                }
            }
        }

        points.append(CGPoint(x: rect.minX, y: rect.maxY))
        return calendarRoundedClosedPolygonPath(
            points: points,
            cornerRadius: cornerRadius
        )
    }
}

private func calendarRoundedClosedPolygonPath(
    points: [CGPoint],
    cornerRadius: CGFloat
) -> Path {
    guard points.count >= 3 else { return Path() }

    let effectiveCornerRadius = max(0, cornerRadius)
    var path = Path()

    for index in points.indices {
        let previous = points[(index - 1 + points.count) % points.count]
        let current = points[index]
        let next = points[(index + 1) % points.count]

        let vectorToPrevious = CGVector(
            dx: previous.x - current.x,
            dy: previous.y - current.y
        )
        let vectorToNext = CGVector(
            dx: next.x - current.x,
            dy: next.y - current.y
        )
        let previousLength = hypot(vectorToPrevious.dx, vectorToPrevious.dy)
        let nextLength = hypot(vectorToNext.dx, vectorToNext.dy)
        guard previousLength > 0.001, nextLength > 0.001 else { continue }

        let radius = min(
            effectiveCornerRadius,
            previousLength / 2,
            nextLength / 2
        )
        let entryPoint = CGPoint(
            x: current.x + vectorToPrevious.dx / previousLength * radius,
            y: current.y + vectorToPrevious.dy / previousLength * radius
        )
        let exitPoint = CGPoint(
            x: current.x + vectorToNext.dx / nextLength * radius,
            y: current.y + vectorToNext.dy / nextLength * radius
        )

        if index == 0 {
            path.move(to: entryPoint)
        } else {
            path.addLine(to: entryPoint)
        }

        if radius > 0 {
            path.addQuadCurve(to: exitPoint, control: current)
        } else {
            path.addLine(to: current)
        }
    }

    path.closeSubpath()
    return path
}
