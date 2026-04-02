import SwiftUI

/// Timeline view matching portrait calendar style — current time ±2 hours.
struct FocusEventFlowView: View {
    let currentEvent: Event
    let currentRange: Event.TimeRange
    let now: Date
    let allOccurrences: [CalendarLayout.EventOccurrence]

    private let visibleHours: CGFloat = 6
    private let calendar = Calendar.current
    private let labelWidth: CGFloat = 42
    private let eventInset: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let w = geo.size.width
            let nowY = h * 0.5
            let pps = h / (visibleHours * 3600)
            let windowStart = now.addingTimeInterval(-Double(visibleHours) * 3600 * 0.5)
            let windowEnd = now.addingTimeInterval(Double(visibleHours) * 3600 * 0.5)

            let eventLeft = labelWidth
            let eventW = w - eventLeft
            let areaW = eventW - eventInset * 2

            // Build interrupt parent-child lookups
            let parentLookup: [UUID: CalendarLayout.EventOccurrence] = {
                var lookup: [UUID: CalendarLayout.EventOccurrence] = [:]
                for occ in allOccurrences where !occ.event.isInterrupt {
                    lookup[occ.event.recurrenceParentId ?? occ.event.id] = occ
                }
                return lookup
            }()

            let childrenLookup: [UUID: [CalendarLayout.EventOccurrence]] = {
                var lookup: [UUID: [CalendarLayout.EventOccurrence]] = [:]
                for occ in allOccurrences {
                    guard let relation = occ.event.interruptRelation,
                          relation.state == .embedded else { continue }
                    lookup[relation.parentEventID, default: []].append(occ)
                }
                return lookup
            }()

            let embeddedIDs: Set<String> = {
                var ids = Set<String>()
                for occ in allOccurrences {
                    guard occ.event.isInterrupt,
                          let relation = occ.event.interruptRelation,
                          relation.state == .embedded,
                          parentLookup[relation.parentEventID] != nil else { continue }
                    ids.insert(occ.id)
                }
                return ids
            }()

            // Exclude embedded interrupts from overlap layout
            let overlapCandidates = allOccurrences.filter { !embeddedIDs.contains($0.id) }
            let overlapSlots = CalendarLayout.overlapLayout(
                for: overlapCandidates,
                on: now,
                calendar: calendar
            )

            let hours = hourMarkers(from: windowStart, to: windowEnd)

            ZStack(alignment: .topLeading) {
                // Grid lines + time labels (hide hour label when too close to now)
                let nowMinutes = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
                ForEach(Array(hours.enumerated()), id: \.offset) { _, hour in
                    let y = nowY + CGFloat(hour.timeIntervalSince(now)) * pps
                    let hourMinutes = calendar.component(.hour, from: hour) * 60

                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: areaW, height: 1)
                        .offset(x: eventLeft + eventInset, y: y)

                    // Hide hour label if too close to current time (like portrait)
                    if abs(hourMinutes - nowMinutes) > 15 {
                        Text(formatHour12(hour))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.secondary)
                            .offset(x: 4, y: y - 7)
                    }
                }

                // Current time label
                Text(formatCurrentTime(now))
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .foregroundColor(.primary)
                    .offset(x: 4, y: nowY - 7)

                // Pass 1: Event block shapes (no titles)
                ForEach(allOccurrences, id: \.id) { occ in
                    if embeddedIDs.contains(occ.id) { EmptyView() }
                    else {
                        let color = CalendarLayout.eventColor(for: occ.event)
                        let blockTop = nowY + CGFloat(occ.range.start.timeIntervalSince(now)) * pps
                        let blockH = CGFloat(occ.range.end.timeIntervalSince(occ.range.start)) * pps
                        let blockBottom = blockTop + blockH
                        let slot = overlapSlots[occ.id] ?? .default
                        let overlapGap: CGFloat = slot.widthFraction < 1 ? 2 : 0
                        let blockW = areaW * slot.widthFraction - overlapGap
                        let blockX = eventLeft + eventInset + areaW * slot.xOffsetFraction
                        let anchorID = occ.event.recurrenceParentId ?? occ.event.id
                        let children = childrenLookup[anchorID] ?? []
                        let childRanges = children.map(\.range)

                        if blockBottom > -20 && blockTop < h + 20 {
                            if !childRanges.isEmpty {
                                let compoundGeo = calendarInterruptParentCompoundGeometry(
                                    parentRange: occ.range,
                                    childRanges: childRanges,
                                    parentWidth: blockW,
                                    parentHeight: max(0, blockH - 3),
                                    horizontalGap: 3,
                                    verticalGap: 3
                                )
                                let compoundShape = CalendarInterruptParentCompoundShape(
                                    cornerRadius: 6,
                                    visibleSegments: compoundGeo.visibleSegments
                                )
                                Rectangle()
                                    .fill(Color(.systemBackground))
                                    .overlay(Rectangle().fill(color.opacity(0.4)))
                                    .mask(compoundShape)
                                    .overlay(compoundShape.stroke(color.opacity(0.7), lineWidth: 1.2))
                                    .frame(width: max(0, blockW), height: max(0, blockH - 3))
                                    .offset(x: blockX, y: blockTop + 1.5)

                                ForEach(children, id: \.id) { child in
                                    let childColor = CalendarLayout.eventColor(for: child.event)
                                    let childTop = nowY + CGFloat(child.range.start.timeIntervalSince(now)) * pps
                                    let childH = CGFloat(child.range.end.timeIntervalSince(child.range.start)) * pps
                                    let childGeo = calendarInterruptChildOverlayGeometry(parentWidth: blockW)
                                    let childX = blockX + childGeo.xOffset
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(Color(.systemBackground))
                                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(childColor.opacity(0.4)))
                                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(childColor.opacity(0.7), lineWidth: 1.2))
                                        .frame(width: max(0, childGeo.width), height: max(0, childH - 3))
                                        .offset(x: childX, y: childTop + 1.5)
                                }
                            } else {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color(.systemBackground))
                                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.opacity(0.4)))
                                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(color.opacity(0.7), lineWidth: 1.2))
                                    .frame(width: max(0, blockW), height: max(0, blockH - 3))
                                    .offset(x: blockX, y: blockTop + 1.5)
                            }
                        }
                    }
                }

                // Pass 2: All titles on top (never clipped by other blocks)
                ForEach(allOccurrences, id: \.id) { occ in
                    let blockTop = nowY + CGFloat(occ.range.start.timeIntervalSince(now)) * pps
                    let blockH = CGFloat(occ.range.end.timeIntervalSince(occ.range.start)) * pps
                    let blockBottom = blockTop + blockH
                    let slot = overlapSlots[occ.id] ?? .default
                    let overlapGap: CGFloat = slot.widthFraction < 1 ? 2 : 0
                    let blockW = areaW * slot.widthFraction - overlapGap
                    let blockX = eventLeft + eventInset + areaW * slot.xOffsetFraction

                    if blockH >= 16 && blockBottom > 0 && blockTop < h {
                        if embeddedIDs.contains(occ.id) {
                            // Embedded child title
                            let parentID = occ.event.interruptRelation?.parentEventID
                            let parentOcc = parentID.flatMap { pid in allOccurrences.first { !$0.event.isInterrupt && ($0.event.recurrenceParentId ?? $0.event.id) == pid } }
                            let parentSlot = parentOcc.flatMap { overlapSlots[$0.id] } ?? .default
                            let parentW = areaW * parentSlot.widthFraction - (parentSlot.widthFraction < 1 ? 2 : 0)
                            let parentX = eventLeft + eventInset + areaW * parentSlot.xOffsetFraction
                            let childGeo = calendarInterruptChildOverlayGeometry(parentWidth: parentW)
                            let childX = parentX + childGeo.xOffset
                            let stickyTop = max(8, -blockTop + 8)
                            let childTitleY = blockTop + 1.5 + stickyTop
                            if childTitleY < blockBottom - 20 && childTitleY < h - 10 {
                                Text(occ.event.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.primary)
                                    .lineLimit(2)
                                    .offset(x: childX + 8, y: childTitleY)
                            }
                        } else {
                            // Parent or regular title
                            let anchorID = occ.event.recurrenceParentId ?? occ.event.id
                            let children = childrenLookup[anchorID] ?? []

                            if !children.isEmpty {
                                // Parent with children: place title below the last child
                                let lastChildBottom = children.map { child in
                                    nowY + CGFloat(child.range.end.timeIntervalSince(now)) * pps
                                }.max() ?? blockTop
                                let titleY = max(lastChildBottom + 10, max(8, blockTop + 1.5 + 8))
                                if titleY < blockBottom - 20 && titleY < h - 10 {
                                    Text(occ.event.title)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.primary)
                                        .lineLimit(2)
                                        .offset(x: blockX + 8, y: titleY)
                                }
                            } else {
                                // Regular event
                                let stickyTop = max(8, -blockTop + 8)
                                Text(occ.event.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.primary)
                                    .lineLimit(2)
                                    .offset(x: blockX + 8, y: blockTop + 1.5 + stickyTop)
                            }
                        }
                    }
                }

                // Now indicator
                let nowColor = Color.primary
                Circle()
                    .fill(nowColor)
                    .frame(width: 8, height: 8)
                    .offset(x: eventLeft + eventInset - 4, y: nowY - 4)
                Rectangle()
                    .fill(nowColor)
                    .frame(width: eventW - eventInset, height: 1.5)
                    .offset(x: eventLeft + eventInset, y: nowY - 0.75)
            }
        }
        .background(Color(.systemBackground))
        .clipped()
    }

    private func hourMarkers(from start: Date, to end: Date) -> [Date] {
        var markers: [Date] = []
        var hour = calendar.nextDate(
            after: start.addingTimeInterval(-3600),
            matching: DateComponents(minute: 0, second: 0),
            matchingPolicy: .strict,
            direction: .forward
        ) ?? start
        while hour <= end {
            markers.append(hour)
            hour = hour.addingTimeInterval(3600)
        }
        return markers
    }

    private func formatHour12(_ date: Date) -> String {
        let hour24 = calendar.component(.hour, from: date)
        let meridiem = hour24 < 12 ? "am" : "pm"
        let hour12 = (hour24 % 12 == 0) ? 12 : (hour24 % 12)
        return "\(hour12) \(meridiem)"
    }

    private static let currentTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "H:mm"
        return f
    }()

    private func formatCurrentTime(_ date: Date) -> String {
        Self.currentTimeFormatter.string(from: date)
    }
}
