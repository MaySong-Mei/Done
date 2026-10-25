//
//  InspectorTimelineSection.swift
//  DoneMac
//
//  The phone detail's Timeline card in the Mac inspector: a scrubbable track
//  (progress fill, interrupt segments, note dots, play head), "Live" and
//  "Add note", the note composer, and the merged list of notes, interrupts
//  and parallel events. Same strings (L()), same math, same store writes as
//  the phone; mouse instead of touch.
//
//  Clock-driven pieces (the live fill, the play head, the near-the-head
//  emphasis) redraw inside TimelineView leaves, so a tick never rebuilds
//  the list or the composer (the phone's gh#164 structure).
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct InspectorTimelineSection: View {
    let event: Event
    let range: Event.TimeRange
    @Bindable var timeline: InspectorTimelineModel
    /// The shared store, observed so a note written elsewhere (the phone,
    /// via sync) redraws the list.
    @ObservedObject var journal: EventStore
    let is24HourTime: Bool
    var onEditingText: (Bool) -> Void = { _ in }

    @State private var isImportingImages = false
    @FocusState private var composerFocused: Bool

    var body: some View {
        let notes = timeline.notes
        let interrupts = timeline.interrupts(range: range)
        let parallels = journal.resolvedParallelTimelineItems(for: event, range: range)
        VStack(alignment: .leading, spacing: 12) {
            header
            track(notes: notes, interrupts: interrupts)
            if timeline.isComposing && timeline.editingNoteID == nil {
                composer(timeLabel: nil)
            }
            list(notes: notes, interrupts: interrupts, parallels: parallels)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .fileImporter(isPresented: $isImportingImages, allowedContentTypes: [.image],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                if let data = try? Data(contentsOf: url) { timeline.addImage(data: data) }
            }
        }
        .onChange(of: composerFocused) { _, focused in onEditingText(focused) }
        // Opened from a block's "Add Note": the composer is already up.
        .onAppear { if timeline.isComposing { composerFocused = true } }
        .onDisappear {
            timeline.flush(now: Date(), range: range)
            onEditingText(false)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text(L(.timeline)).font(.headline)
            Spacer()
            if timeline.mode == .manual {
                Button { timeline.resumeLive() } label: {
                    Label(L(.liveLabel), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .font(.caption.weight(.semibold))
            }
            Button {
                timeline.beginAdding(now: Date())
                composerFocused = true
            } label: {
                Label(L(.addNote), systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .font(.caption.weight(.semibold))
            .disabled(timeline.isComposing)
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
    }

    // MARK: - Track

    private func track(notes: [EventLogTimelineNote],
                       interrupts: [CalendarResolvedInterruptTimelineItem]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let width = max(geo.size.width, 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15)).frame(width: width, height: 4)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let state = timeline.resolvedState(now: context.date, range: range)
                        Capsule()
                            .fill(EventTypeTemplateStore.color(for: event.type))
                            .frame(width: width * calendarEventTimelineLiveProgress(now: context.date, range: range),
                                   height: 4)
                            .onChange(of: context.date) { _, now in timeline.tick(now: now) }
                            .overlay(alignment: .leading) {
                                Circle()
                                    .fill(Color.primary)
                                    .frame(width: 12, height: 12)
                                    .offset(x: width * state.displayProgress - 6)
                            }
                    }
                    ForEach(interrupts) { item in
                        if let clipped = item.clippedRange {
                            let start = calendarEventTimelineProgress(for: clipped.start, range: range)
                            let end = calendarEventTimelineProgress(for: clipped.end, range: range)
                            Capsule()
                                .fill(EventTypeTemplateStore.color(for: item.childEvent.type))
                                .frame(width: max(8, width * max(0.02, end - start)), height: 4)
                                .offset(x: width * start)
                        }
                    }
                    ForEach(notes) { note in
                        Circle()
                            .fill(Color.primary.opacity(0.7))
                            .frame(width: 6, height: 6)
                            .offset(x: width * calendarEventTimelineProgress(for: note.createdAt, range: range) - 3)
                    }
                }
                .frame(height: 16)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            timeline.scrub(to: value.location.x / width, now: Date(), range: range)
                        }
                )
            }
            .frame(height: 16)
            HStack {
                Text(timeLabel(range.start))
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(timeLabel(timeline.resolvedState(now: context.date, range: range).snapshotDate))
                        .fontWeight(.semibold)
                }
                Spacer()
                Text(timeLabel(range.end))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - List

    private enum Row: Identifiable {
        case note(EventLogTimelineNote)
        case interrupt(CalendarResolvedInterruptTimelineItem)
        case parallel(CalendarResolvedParallelTimelineItem)

        var id: String {
            switch self {
            case .note(let n): return "note-\(n.id)"
            case .interrupt(let i): return "interrupt-\(i.id)"
            case .parallel(let p): return "parallel-\(p.id)"
            }
        }
        var date: Date {
            switch self {
            case .note(let n): return n.createdAt
            case .interrupt(let i): return i.childRange.start
            case .parallel(let p): return p.childRange.start
            }
        }
    }

    @ViewBuilder
    private func list(notes: [EventLogTimelineNote],
                      interrupts: [CalendarResolvedInterruptTimelineItem],
                      parallels: [CalendarResolvedParallelTimelineItem]) -> some View {
        let rows = (notes.map(Row.note) + interrupts.map(Row.interrupt) + parallels.map(Row.parallel))
            .sorted { $0.date < $1.date }
        if rows.isEmpty && !timeline.isComposing {
            Text(L(.noNotesYet))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows) { row in
                    switch row {
                    case .note(let note): noteRow(note)
                    case .interrupt(let item): interruptRow(item)
                    case .parallel(let item): parallelRow(item)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func noteRow(_ note: EventLogTimelineNote) -> some View {
        if timeline.isComposing && timeline.editingNoteID == note.id {
            composer(timeLabel: timeLabel(note.createdAt), deleting: note)
        } else {
            HStack(alignment: .top, spacing: 8) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let near = calendarEventTimelineNoteIsNear(
                        note, at: timeline.resolvedState(now: context.date, range: range).snapshotDate, range: range)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle()
                            .fill(Color.primary.opacity(near ? 1 : 0.4))
                            .frame(width: 8, height: 8)
                        Text(timeLabel(note.createdAt))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(near ? Color.secondary : Color.secondary.opacity(0.5))
                    }
                }
                .fixedSize()
                VStack(alignment: .leading, spacing: 6) {
                    if !note.text.isEmpty {
                        Text(note.text)
                            .font(.callout)
                            // No .textSelection: it would take the double-click
                            // that opens the editor (copy from the editor).
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !note.images.isEmpty {
                        imageStrip(note.images.map { .existing($0) }, removable: false)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { edit(note) }
            .contextMenu {
                Button(L(.edit)) { edit(note) }
                Button(L(.delete), role: .destructive) { timeline.delete(note) }
            }
        }
    }

    private func edit(_ note: EventLogTimelineNote) {
        timeline.beginEditing(note, now: Date())
        composerFocused = true
    }

    private func interruptRow(_ item: CalendarResolvedInterruptTimelineItem) -> some View {
        let tint = EventTypeTemplateStore.color(for: item.childEvent.type)
        return TimelineView(.periodic(from: .now, by: 1)) { context in
            let near = calendarEventTimelineInterruptIsNear(
                item, at: timeline.resolvedState(now: context.date, range: range).snapshotDate)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Circle().fill(tint.opacity(near ? 1 : 0.4)).frame(width: 8, height: 8)
                    Text("\(timeLabel(item.childRange.start)) - \(timeLabel(item.childRange.end))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(near ? Color.secondary : Color.secondary.opacity(0.5))
                }
                Text(item.childEvent.title)
                    .font(.callout)
                    .foregroundStyle(near ? Color.primary : Color.primary.opacity(0.5))
                    .padding(.leading, 16)
            }
        }
    }

    private func parallelRow(_ item: CalendarResolvedParallelTimelineItem) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1)
                .fill(EventTypeTemplateStore.color(for: item.childEvent.type).opacity(0.6))
                .frame(width: 2, height: 14)
            Text(L(.parallelWith)).font(.caption2).foregroundStyle(.tertiary)
            Text(item.childEvent.title).font(.caption2.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 0)
            Text("\(timeLabel(item.childRange.start)) – \(timeLabel(item.childRange.end))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Composer

    private func composer(timeLabel label: String?, deleting note: EventLogTimelineNote? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let label {
                Text(label).font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
            }
            TextEditor(text: $timeline.draftText)
                .font(.callout)
                .focused($composerFocused)
                .frame(minHeight: 60, maxHeight: 160)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            if timeline.imageCount > 0 {
                imageStrip(timeline.existingImages.map { .existing($0) } + timeline.imageDrafts.map { .draft($0) },
                           removable: true)
            }
            HStack(spacing: 10) {
                Button { isImportingImages = true } label: { Image(systemName: "photo.badge.plus") }
                    .buttonStyle(.borderless)
                    .disabled(timeline.imageCount >= InspectorTimelineModel.maxImages)
                    .help("Attach images")
                if let note {
                    Button(role: .destructive) { timeline.delete(note) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button(L(.cancel)) { timeline.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button(L(.save)) { timeline.save(now: Date(), range: range) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!timeline.canSave)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Images

    private enum Thumb: Identifiable {
        case existing(AgenticIntakeImageRef)
        case draft(InspectorTimelineModel.ImageDraft)
        var id: UUID {
            switch self {
            case .existing(let r): return r.id
            case .draft(let d): return d.id
            }
        }
    }

    private func imageStrip(_ thumbs: [Thumb], removable: Bool) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(thumbs) { thumb in
                    ZStack(alignment: .topTrailing) {
                        thumbImage(thumb)
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .onTapGesture { open(thumb) }
                        if removable {
                            Button {
                                switch thumb {
                                case .existing(let r): timeline.removeExistingImage(r.id)
                                case .draft(let d): timeline.removeImageDraft(d.id)
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.5))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 4, y: -4)
                        }
                    }
                }
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func thumbImage(_ thumb: Thumb) -> some View {
        let image: NSImage? = {
            switch thumb {
            case .existing(let r): return NSImage(contentsOf: timeline.imageURL(r))
            case .draft(let d): return NSImage(data: d.data)
            }
        }()
        if let image {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            Color.secondary.opacity(0.15)
        }
    }

    /// The phone opens a full-screen viewer; the Mac hands the file to the
    /// default viewer (Preview / Quick Look).
    private func open(_ thumb: Thumb) {
        guard case .existing(let ref) = thumb else { return }
        NSWorkspace.shared.open(timeline.imageURL(ref))
    }

    // MARK: - Format

    private func timeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        if is24HourTime {
            formatter.dateFormat = "H:mm"
        } else {
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "h:mm a"
            formatter.amSymbol = "am"
            formatter.pmSymbol = "pm"
        }
        return formatter.string(from: date)
    }
}
