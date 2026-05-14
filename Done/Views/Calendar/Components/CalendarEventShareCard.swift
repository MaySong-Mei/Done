//
//  CalendarEventShareCard.swift
//  Done
//
//  Shareable card snapshot of a single event, mirroring the detail page's
//  horizontal timeline (slider track with interrupt + note markers, time
//  labels, and the log entries listed below).
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Share Context

/// Identifies a single event-occurrence pair that should be presented in the
/// event-share sheet. Used as the `item` for `.sheet(item:)` presentation.
struct CalendarEventShareContext: Identifiable {
    let event: Event
    let range: Event.TimeRange
    let date: Date

    var id: String {
        "\(event.id.uuidString)|\(range.start.timeIntervalSince1970)"
    }
}

// MARK: - Single Event Share Card

/// A timeline note paired with its pre-loaded images. Pre-loading is required
/// because `ImageRenderer` renders synchronously — `.onAppear`-based async
/// fetches would never fire before the snapshot is taken.
struct CalendarEventShareNote: Identifiable {
    let note: EventLogTimelineNote
    let images: [UIImage]

    var id: UUID { note.id }
    var text: String { note.text }
    var createdAt: Date { note.createdAt }
}

struct CalendarEventShareCard: View {
    let parentEvent: Event
    let parentRange: Event.TimeRange
    let interrupts: [(event: Event, range: Event.TimeRange)]
    let notes: [CalendarEventShareNote]
    let date: Date

    static let cardWidth: CGFloat = 360

    private var calendar: Calendar { Calendar.current }

    /// Merged, time-sorted list of interrupt + note entries shown below the
    /// slider. Each row knows what color dot + label to render and whether
    /// it carries images.
    private struct LogRow: Identifiable {
        let id: String
        let date: Date
        let title: String
        let color: Color
        let isInterrupt: Bool
        let images: [UIImage]
    }

    private var logRows: [LogRow] {
        var rows: [LogRow] = []
        for interrupt in interrupts {
            rows.append(LogRow(
                id: "interrupt-\(interrupt.event.id.uuidString)",
                date: interrupt.range.start,
                title: interrupt.event.title.isEmpty ? "Untitled" : interrupt.event.title,
                color: EventTypeTemplateStore.color(for: interrupt.event.type),
                isInterrupt: true,
                images: []
            ))
        }
        for shareNote in notes {
            rows.append(LogRow(
                id: "note-\(shareNote.note.id.uuidString)",
                date: shareNote.createdAt,
                title: shareNote.text,
                color: Color.secondary,
                isInterrupt: false,
                images: shareNote.images
            ))
        }
        return rows.sorted { $0.date < $1.date }
    }

    /// Approximate card height for sizing the preview. Slightly over-estimates
    /// natural intrinsic height so the preview never clips. The renderer no
    /// longer uses this — it captures the card at its natural size — so this
    /// only affects the sheet preview layout.
    var cardHeight: CGFloat {
        // Chrome (header + title + type chip + slider + time labels + paddings)
        let chrome: CGFloat = 260
        let perRow: CGFloat = 46
        let imageStripExtra: CGFloat = 56 // 44pt thumbs + 6pt top spacing + slack
        let baseRowsHeight = CGFloat(logRows.count) * perRow
        let imageStripCount = logRows.filter { !$0.images.isEmpty }.count
        let imageStripsHeight = CGFloat(imageStripCount) * imageStripExtra
        let emptyPlaceholderHeight: CGFloat = logRows.isEmpty ? 30 : 0
        return chrome + baseRowsHeight + imageStripsHeight + emptyPlaceholderHeight
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            titleAndType
            timelineSlider
            if logRows.isEmpty {
                Text("No interrupts or notes")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(logRows) { row in
                        logEntry(row)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: Self.cardWidth)
        .background(Color(.systemBackground))
    }

    // MARK: - Header

    private var header: some View {
        Text(headerDateLabel.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .tracking(1.5)
    }

    private var titleAndType: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(parentEvent.title.isEmpty ? "Untitled" : parentEvent.title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.primary)
                .lineLimit(2)
            HStack(spacing: 6) {
                Circle()
                    .fill(EventTypeTemplateStore.color(for: parentEvent.type))
                    .frame(width: 8, height: 8)
                Text(parentEvent.type)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.12), in: Capsule())
        }
    }

    // MARK: - Slider (mirrors detail page timeline)

    private var timelineSlider: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let trackWidth = max(geo.size.width, 1)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.18))
                        .frame(width: trackWidth, height: 4)

                    // Interrupt capsules on track
                    ForEach(Array(interrupts.enumerated()), id: \.offset) { _, item in
                        let startP = progress(for: item.range.start)
                        let endP = progress(for: item.range.end)
                        let width = max(8, trackWidth * max(0.02, endP - startP))
                        let tint = EventTypeTemplateStore.color(for: item.event.type)
                        Capsule()
                            .fill(tint)
                            .frame(width: width, height: 4)
                            .offset(x: trackWidth * startP)
                    }

                    // Note dots on track
                    ForEach(notes) { note in
                        let p = progress(for: note.createdAt)
                        Circle()
                            .fill(Color.primary.opacity(0.55))
                            .frame(width: 7, height: 7)
                            .offset(x: trackWidth * p - 3.5)
                    }
                }
                .frame(height: 22)
            }
            .frame(height: 22)

            HStack {
                Text(timeLabel(parentRange.start))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(timeLabel(parentRange.end))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Log list

    private func logEntry(_ row: LogRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(row.color)
                .frame(width: 7, height: 7)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(timeLabel(row.date))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Text(row.title)
                        .font(.system(size: 14, weight: row.isInterrupt ? .semibold : .regular))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
                if !row.images.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(row.images.prefix(5).indices, id: \.self) { idx in
                            Image(uiImage: row.images[idx])
                                .resizable()
                                .scaledToFill()
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        if row.images.count > 5 {
                            Text("+\(row.images.count - 5)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 44, height: 44)
                                .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Helpers

    private func progress(for date: Date) -> CGFloat {
        let total = parentRange.end.timeIntervalSince(parentRange.start)
        guard total > 0 else { return 0 }
        let elapsed = date.timeIntervalSince(parentRange.start)
        return CGFloat(max(0, min(1, elapsed / total)))
    }

    private var headerDateLabel: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMM d"
        return f.string(from: date)
    }

    private func timeLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        f.amSymbol = "am"
        f.pmSymbol = "pm"
        return f.string(from: d)
    }
}

// MARK: - Share Sheet

struct CalendarEventShareSheet: View {
    let context: CalendarEventShareContext
    let onDismiss: () -> Void

    @EnvironmentObject private var store: EventStore

    var body: some View {
        let interrupts = calendarEventShareInterrupts(
            for: context.event,
            on: context.date,
            in: store.calendarEvents
        )
        let occurrenceContext = CalendarEventOccurrenceContext(
            eventID: context.event.id,
            occurrenceDate: context.date,
            occurrenceID: nil,
            isAllDay: context.event.isAllDay,
            source: .timelineTap
        )
        let rawNotes = (store.logRecord(for: occurrenceContext)?.timelineItems ?? [])
            .compactMap(\.noteValue)
            .sorted { $0.createdAt < $1.createdAt }
        let assetStore = AgenticIntakeAssetStore()
        let shareNotes: [CalendarEventShareNote] = rawNotes.map { note in
            let loaded = note.images.compactMap { assetStore.loadImage(for: $0) }
            return CalendarEventShareNote(note: note, images: loaded)
        }
        let card = CalendarEventShareCard(
            parentEvent: context.event,
            parentRange: context.range,
            interrupts: interrupts,
            notes: shareNotes,
            date: context.date
        )
        let cardHeight = card.cardHeight

        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Text("Share event")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)
                    HStack {
                        Spacer()
                        Button {
                            onDismiss()
                        } label: {
                            Text("Done")
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 14)
                                .frame(height: 40)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

                GeometryReader { proxy in
                    let topInset: CGFloat = 16
                    let shareEstimate: CGFloat = 48
                    let minSpacing: CGFloat = 14
                    let bottomInset: CGFloat = 12
                    let reserved = topInset + shareEstimate + minSpacing + bottomInset
                    let cardHeightBudget = max(0, proxy.size.height - reserved)
                    let cardWidthBudget = max(0, proxy.size.width - 24)
                    let scaleByHeight = cardHeight > 0 ? cardHeightBudget / cardHeight : 1
                    let scaleByWidth = cardWidthBudget / CalendarEventShareCard.cardWidth
                    let previewScale = min(scaleByHeight, scaleByWidth, 0.92)

                    VStack(spacing: 0) {
                        ScrollView {
                            VStack(spacing: 0) {
                                card
                                    .scaleEffect(previewScale)
                                    .frame(
                                        width: CalendarEventShareCard.cardWidth * previewScale,
                                        height: cardHeight * previewScale
                                    )
                                    .shadow(color: Color.black.opacity(0.15), radius: 18, x: 0, y: 6)
                                    .padding(.top, topInset)
                            }
                            .frame(maxWidth: .infinity)
                        }

                        if let image = calendarEventShareCardRender(card) {
                            let item = CalendarEventShareItem(image: image)
                            ShareLink(
                                item: item,
                                preview: SharePreview("Event on Done", image: item)
                            ) {
                                HStack(spacing: 6) {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.system(size: 15, weight: .semibold))
                                    Text("Share")
                                        .font(.system(size: 16, weight: .semibold))
                                }
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 20)
                                .frame(maxWidth: .infinity)
                                .frame(height: shareEstimate)
                                .contentShape(Capsule())
                                .background(Color.black.opacity(0.001), in: Capsule())
                                .glassEffect(.regular.interactive(), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 24)
                            .padding(.top, minSpacing)
                            .padding(.bottom, bottomInset)
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .background(Color(.systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

// MARK: - Transferable

struct CalendarEventShareItem: Transferable {
    let image: UIImage

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in
            item.image.pngData() ?? Data()
        }
    }
}

// MARK: - Renderer

@MainActor
func calendarEventShareCardRender(_ card: CalendarEventShareCard) -> UIImage? {
    // Renders at the card's natural intrinsic height (width is pinned inside
    // the card body itself). Pre-computing a fixed height clipped overflow
    // content — letting SwiftUI decide the canvas size avoids that entirely.
    let renderer = ImageRenderer(content: card)
    renderer.scale = 3
    return renderer.uiImage
}

// MARK: - Helpers

/// Resolve the interrupts belonging to `parent` on the given day, clipped to
/// that day. Returns sorted by start.
func calendarEventShareInterrupts(
    for parent: Event,
    on date: Date,
    in events: [Event]
) -> [(event: Event, range: Event.TimeRange)] {
    let calendar = Calendar.current
    let dayStart = calendar.startOfDay(for: date)
    let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
    let parentID = parent.recurrenceParentId ?? parent.id

    return events.compactMap { candidate -> (event: Event, range: Event.TimeRange)? in
        guard let relation = candidate.interruptRelation,
              relation.parentEventID == parentID,
              let rawRange = candidate.timeRanges.first else {
            return nil
        }
        let start = max(rawRange.start, dayStart)
        let end = min(rawRange.end, dayEnd)
        guard end > start else { return nil }
        return (candidate, Event.TimeRange(start: start, end: end))
    }
    .sorted { $0.range.start < $1.range.start }
}
