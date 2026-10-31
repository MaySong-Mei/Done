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

// MARK: - Share Sheet

struct CalendarEventShareSheet: View {
    let context: CalendarEventShareContext
    let onDismiss: () -> Void

    @EnvironmentObject private var store: EventStore

    var body: some View {
        let interrupts = calendarEventShareInterrupts(
            for: context.event,
            on: context.date,
            in: store.rawCalendarEvents
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
                    Text(L(.shareEvent))
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)
                    HStack {
                        Spacer()
                        Button {
                            onDismiss()
                        } label: {
                            Text(L(.done))
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 14)
                                .frame(height: 40)
                                .contentShape(Capsule())
                                .background(Color.black.opacity(0.001), in: Capsule())
                                .glassEffect(.regular.interactive(), in: Capsule())
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
