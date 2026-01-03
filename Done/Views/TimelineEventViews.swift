//
//  TimelineEventViews.swift
//  Done
//
//  Extracted from DayTimelineView.swift
//

import SwiftUI

// MARK: - Past Time Overlay
struct PastTimeOverlay: View {
    let date: Date
    let geometry: TimelineGeometry
    let width: CGFloat
    let currentTime: Date

    private var isToday: Bool {
        Calendar.current.isDateInToday(date)
    }

    private var isPast: Bool {
        Calendar.current.compare(date, to: Date(), toGranularity: .day) == .orderedAscending
    }

    private var shouldShowOverlay: Bool {
        isToday || isPast
    }

    private var elapsedHeight: CGFloat {
        if isPast {
            return geometry.totalHeight
        } else if isToday {
            return geometry.yPosition(for: currentTime)
        } else {
            return 0
        }
    }

    var body: some View {
        if shouldShowOverlay && elapsedHeight > 0 {
            ZStack(alignment: .topLeading) {
                glassBase
                    .frame(width: width, height: elapsedHeight)

                StripeOverlay()
                    .frame(width: width, height: elapsedHeight)
            }
            .frame(width: width, height: geometry.totalHeight, alignment: .topLeading)
            .allowsHitTesting(false)
        }
    }

    private var glassBase: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.white.opacity(0.22))
                    .blendMode(.screen)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 0.6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.18),
                                Color.white.opacity(0.04),
                                Color.clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .blendMode(.overlay)
            )
            .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 2)
    }

    private struct StripeOverlay: View {
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            Canvas { context, size in
                let spacing: CGFloat = 8
                let lineWidth: CGFloat = 0.5
                let color: Color = (colorScheme == .dark ? Color.white : Color.gray)
                    .opacity(colorScheme == .dark ? 0.12 : 0.08)

                context.stroke(
                    Path { path in
                        var x: CGFloat = -size.height
                        while x < size.width + size.height {
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x + size.height, y: size.height))
                            x += spacing
                        }
                    },
                    with: .color(color),
                    lineWidth: lineWidth
                )
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

// MARK: - Day Column
struct DayColumn: View {
    let date: Date
    let entries: [TimeEntry]
    let geometry: TimelineGeometry
    let viewMode: TimelineViewMode
    let showCurrentTime: Bool
    let currentTime: Date
    @Binding var selectedEntry: TimeEntry?
    @Binding var draftEntry: TimeEntry?
    @Binding var draftEditEntry: TimeEntry?

    struct DaySlice: Identifiable {
        let id: UUID
        let entry: TimeEntry
        let start: Date
        let end: Date
        let style: TimelineEventBlock.EventStyle
        let isDraft: Bool
    }

    var body: some View {
        GeometryReader { proxy in
            let columnWidth = max(1, proxy.size.width)
            let slices = slicesForDay()

            ZStack(alignment: .topLeading) {
                TimelineGrid(geometry: geometry)
                    .frame(width: columnWidth)
                    .contentShape(Rectangle())
                    .simultaneousGesture(createDraftGesture) // long-press empty area to create draft

                PastTimeOverlay(
                    date: date,
                    geometry: geometry,
                    width: columnWidth,
                    currentTime: currentTime
                )

                ForEach(slices) { slice in
                    TimelineEventBlock(
                        entry: slice.entry,
                        renderStart: slice.start,
                        renderEnd: slice.end,
                        geometry: geometry,
                        availableWidth: columnWidth,
                        column: 0,
                        totalColumns: 1,
                        showsLabels: viewMode != .week,
                        style: slice.style,
                        selectedEntry: $selectedEntry,
                        draftEntry: $draftEntry,
                        draftEditEntry: $draftEditEntry,
                        isDraft: slice.isDraft
                    )
                }

                if showCurrentTime {
                    CurrentTimeLine(geometry: geometry, currentTime: currentTime)
                }
            }
            .frame(width: columnWidth, height: geometry.totalHeight, alignment: .topLeading)
        }
        .frame(height: geometry.totalHeight)
    }

    func slicesForDay() -> [DaySlice] {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: date)
        let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart)!

        var all: [(TimeEntry, TimelineEventBlock.EventStyle, Bool)] = entries.map { ($0, .completed, false) }

        if let active = DataManager.shared.ongoingEntry {
            all.append((active, .active, false))
        }

        if let draft = draftEntry {
            all.append((draft, .active, true))
        }

        let now = currentTime

        return all.compactMap { entry, style, isDraft in
            let entryEnd = entry.endTime ?? now
            let start = max(entry.startTime, dayStart)
            let end = min(entryEnd, dayEnd)
            guard end > start else { return nil }
            return DaySlice(id: entry.id, entry: entry, start: start, end: end, style: style, isDraft: isDraft)
        }
        .sorted { $0.start < $1.start }
    }
}

// MARK: - Timeline Event Block
struct TimelineEventBlock: View {
    let entry: TimeEntry
    let renderStart: Date
    let renderEnd: Date
    let geometry: TimelineGeometry
    let availableWidth: CGFloat
    let column: Int
    let totalColumns: Int
    let showsLabels: Bool
    let style: EventStyle
    @Binding var selectedEntry: TimeEntry?
    @Binding var draftEntry: TimeEntry?
    @Binding var draftEditEntry: TimeEntry?
    let isDraft: Bool
    @ObservedObject var dataManager = DataManager.shared
    enum ResizeHandle {
        case top
        case bottom
    }
    @GestureState var dragTranslation: CGSize = .zero
    @GestureState var isDragging: Bool = false
    @State var dragArmed = false
    @GestureState var activeHandle: ResizeHandle? = nil
    @GestureState var resizeTopOffset: CGFloat = 0
    @GestureState var resizeBottomOffset: CGFloat = 0

    enum EventStyle {
        case completed
        case active
    }

    var body: some View {
        if renderEnd > renderStart {
            let (displayStart, displayEnd) = draftAdjustedTimes()
            let startY = geometry.yPosition(for: displayStart)
            let height = geometry.height(from: displayStart, to: displayEnd)
            let dragSeconds = dragTimeDeltaSeconds
            let dragDisplayStart = displayStart.addingTimeInterval(dragSeconds)
            let dragDisplayEnd = displayEnd.addingTimeInterval(dragSeconds)

            let contentWidth = max(0, availableWidth - geometry.leftMargin - geometry.rightMargin)
            let blockWidth = max(0, contentWidth / CGFloat(totalColumns))
            let xOffset = geometry.leftMargin + (blockWidth * CGFloat(column))
            let dragInflate: CGFloat = isDragging ? 6 : 0

            VStack(alignment: .leading, spacing: 4) {
                if showsLabels && !dataManager.wordlessMode {
                    Text(entry.templateName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(labelColor)
                        .lineLimit(1)

                    if height > 40 {
                        Text(formatTimeRange(start: dragDisplayStart, end: dragDisplayEnd))
                            .font(.caption2)
                            .foregroundColor(labelColor.opacity(0.8))
                    }
                }
            }
            .padding(8)
            .frame(width: max(1, blockWidth - 4 + dragInflate), height: max(1, height + dragInflate), alignment: .topLeading)
            .background(eventBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder((Color(hex: entry.colorHex) ?? .blue), lineWidth: style == .active ? 0.8 : 0)
            )
            .overlay(resizeHandles(height: height), alignment: .topLeading) // draft-only resize handles
            .shadow(color: Color.black.opacity(isDragging ? 0.18 : 0), radius: isDragging ? 6 : 0, x: 0, y: 2) // drag feedback
            .animation(.easeOut(duration: 0.12), value: isDragging) // animate drag state
            .cornerRadius(6)
            .offset(
                x: xOffset + 2 - (dragInflate / 2),
                y: startY + (isDragging ? dragTranslation.height : 0) - (dragInflate / 2)
            )
            .onTapGesture {
                if isDraft {
                    draftEditEntry = entry
                    draftEntry = nil
                } else {
                    selectedEntry = entry
                }
            }
            .onLongPressGesture(
                minimumDuration: 0.25,
                maximumDistance: 4,
                pressing: { pressing in
                    if !pressing {
                        dragArmed = false
                    }
                },
                perform: {
                    guard style == .completed else { return }
                    dragArmed = true
                }
            )
            .simultaneousGesture(dragGesture, including: dragArmed ? .all : .none) // ignore until armed
        }
    }

    @ViewBuilder
    private var eventBackground: some View {
        let base = Color(hex: entry.colorHex) ?? .blue
        switch style {
        case .completed:
            base
        case .active:
            ActiveStripeFill(color: base)
        }
    }

    private var labelColor: Color {
        let base = Color(hex: entry.colorHex) ?? .blue
        return style == .active ? base : .white
    }

    private struct ActiveStripeFill: View {
        let color: Color

        var body: some View {
            Canvas { context, size in
                let spacing: CGFloat = 8
                let lineWidth: CGFloat = 1
                let stripeColor = color.opacity(0.35)

                context.stroke(
                    Path { path in
                        var x: CGFloat = -size.height
                        while x < size.width + size.height {
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x + size.height, y: size.height))
                            x += spacing
                        }
                    },
                    with: .color(stripeColor),
                    lineWidth: lineWidth
                )
            }
        }
    }

    private var dragTimeDeltaSeconds: TimeInterval {
        guard style == .completed else { return 0 }
        let hoursDelta = dragTranslation.height / geometry.hourHeight
        return TimeInterval(hoursDelta * 3600)
    }

    private func formatTimeRange(start: Date, end: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short

        let startStr = formatter.string(from: start)
        let endStr = formatter.string(from: end)
        return "\(startStr) - \(endStr)"
    }
}

// MARK: - Current Time Line
struct CurrentTimeLine: View {
    let geometry: TimelineGeometry
    let currentTime: Date

    var body: some View {
        let y = geometry.yPosition(for: currentTime)

        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.red)
                .frame(height: 2)
                .offset(x: geometry.leftMargin)

            Circle()
                .fill(Color.red)
                .frame(width: 12, height: 12)
                .offset(x: geometry.leftMargin - 6)
        }
        .offset(y: y)
    }
}
