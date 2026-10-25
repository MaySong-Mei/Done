//
//  InspectorShareSheet.swift
//  DoneMac
//
//  The phone's event share sheet on the Mac: the same card (the shared
//  CalendarEventShareCard — slider, interrupts, notes with their images),
//  built from the same inputs, rendered with ImageRenderer. The phone's
//  share sheet becomes the Mac's: Share… (the system picker), Copy, Save….
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct InspectorShareSheet: View {
    let event: Event
    let range: Event.TimeRange
    let occurrence: CalendarEventOccurrenceContext
    @ObservedObject var store: EventStore
    let onDismiss: () -> Void

    var body: some View {
        let card = Self.card(event: event, range: range, occurrence: occurrence, store: store)
        let image = Self.render(card)
        VStack(spacing: 12) {
            HStack {
                Text(L(.shareEvent)).font(.headline)
                Spacer()
                Button(L(.done), action: onDismiss).keyboardShortcut(.cancelAction)
            }
            ScrollView {
                card
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(radius: 4, y: 2)
                    .padding(8)
            }
            .frame(maxHeight: 520)
            HStack {
                if let image {
                    ShareLink(item: ShareImage(image: image),
                              preview: SharePreview(event.title, image: Image(nsImage: image))) {
                        Label(L(.toolShare), systemImage: "square.and.arrow.up")
                    }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([image])
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    Button { save(image) } label: {
                        Label("Save…", systemImage: "square.and.arrow.down")
                    }
                }
                Spacer()
            }
        }
        .padding(16)
        .frame(width: CalendarEventShareCard.cardWidth + 64)
    }

    /// The phone sheet's card inputs: the day's interrupts, the occurrence's
    /// notes oldest first, each note's images loaded up front (ImageRenderer
    /// is synchronous).
    @MainActor
    static func card(event: Event, range: Event.TimeRange, occurrence: CalendarEventOccurrenceContext,
                     store: EventStore) -> CalendarEventShareCard {
        let interrupts = calendarEventShareInterrupts(for: event, on: occurrence.occurrenceDate,
                                                      in: store.rawCalendarEvents)
        let assets = AgenticIntakeAssetStore()
        let notes = (store.logRecord(for: occurrence)?.timelineItems ?? [])
            .compactMap(\.noteValue)
            .sorted { $0.createdAt < $1.createdAt }
            .map { note in
                CalendarEventShareNote(note: note,
                                       images: note.images.compactMap { NSImage(contentsOf: assets.absoluteURL(for: $0)) })
            }
        return CalendarEventShareCard(parentEvent: event, parentRange: range, interrupts: interrupts,
                                      notes: notes, date: occurrence.occurrenceDate)
    }

    @MainActor
    static func render(_ card: CalendarEventShareCard) -> NSImage? {
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        return renderer.nsImage
    }

    private func save(_ image: NSImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = (event.title.isEmpty ? "Event" : event.title) + ".png"
        guard panel.runModal() == .OK, let url = panel.url, let data = ShareImage.png(image) else { return }
        try? data.write(to: url)
    }
}

/// The card as a PNG for the system share picker (the phone's
/// CalendarEventShareItem, NSImage-backed).
struct ShareImage: Transferable {
    let image: NSImage

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in png(item.image) ?? Data() }
    }

    static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
