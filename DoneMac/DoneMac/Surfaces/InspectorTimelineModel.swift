//
//  InspectorTimelineModel.swift
//  DoneMac
//
//  The phone detail's timeline + note log, Mac-side: one occurrence's
//  scrubbable track (live / manual), the notes and interrupts on it, and a
//  note composer. Writes go through the same store calls the phone makes
//  (appendTimelineNote / updateTimelineNote / deleteTimelineNote), so a note
//  added here is the note the phone shows, and vice versa.
//
//  The math (progress <-> date, snapping, live resume) is the phone's,
//  shared in CalendarEventTimelineModel.swift. What differs is input only:
//  a mouse drag instead of a finger, no haptics, and a draft that lives in
//  this model (the pane is rebuilt per selection, so the draft is flushed
//  when the pane goes away — the phone's flushTimelineNoteDraft rule).
//

import Foundation
import Observation

@MainActor
@Observable
final class InspectorTimelineModel {
    /// The occurrence this timeline belongs to; fixed for the model's life
    /// (the inspector rebuilds per selection).
    let occurrence: CalendarEventOccurrenceContext

    @ObservationIgnored private let store: EventStore
    @ObservationIgnored private let assets: AgenticIntakeAssetStore

    // MARK: Track state

    private(set) var mode: CalendarEventTimelineMode = .live
    private(set) var manualProgress: CGFloat = 0
    /// The last scrub; a manual track resumes live after the phone's idle
    /// interval (calendarEventTimelineShouldAutoResumeLive).
    private(set) var lastInteractionAt: Date?
    private var previousSelectedMinute = 0
    private var wasSnappedToNote = false

    // MARK: Composer state

    private(set) var isComposing = false
    /// The note being edited; nil while composing a new one.
    private(set) var editingNoteID: UUID?
    var draftText = ""
    /// Images already saved for the note being edited (the user can drop some).
    private(set) var existingImages: [AgenticIntakeImageRef] = []
    /// Picked image files not yet imported into the asset store.
    private(set) var imageDrafts: [ImageDraft] = []
    /// A note this model appended while flushing a draft — later flushes
    /// update it instead of appending another (the phone's id handoff).
    private var flushCreatedNoteID: UUID?

    struct ImageDraft: Identifiable, Equatable {
        let id: UUID
        let data: Data
    }

    /// The phone's per-note image cap.
    static let maxImages = 5

    init(occurrence: CalendarEventOccurrenceContext, store: EventStore,
         assets: AgenticIntakeAssetStore = AgenticIntakeAssetStore()) {
        self.occurrence = occurrence
        self.store = store
        self.assets = assets
    }

    // MARK: - Reads

    /// The occurrence's notes, oldest first (the phone's `timelineNotes`).
    var notes: [EventLogTimelineNote] {
        (store.logRecord(for: occurrence)?.timelineItems ?? [])
            .compactMap(\.noteValue)
            .sorted { $0.createdAt < $1.createdAt }
    }

    func interrupts(range: Event.TimeRange) -> [CalendarResolvedInterruptTimelineItem] {
        store.resolvedInterruptTimelineItems(for: occurrence, range: range)
    }

    /// Where the thumb sits and which instant a new note lands on.
    func resolvedState(now: Date, range: Event.TimeRange) -> CalendarEventTimelineResolvedState {
        calendarEventTimelineResolvedState(mode: mode, manualProgress: manualProgress, now: now, range: range)
    }

    var imageCount: Int { existingImages.count + imageDrafts.count }

    // MARK: - Track

    /// A scrub to `rawProgress` (0...1 along the track): snaps to a note
    /// within two minutes, and returns to live when it lands on "now".
    func scrub(to rawProgress: CGFloat, now: Date, range: Event.TimeRange) {
        let resolution = calendarEventTimelineResolveDrag(
            rawProgress: rawProgress, range: range, notes: notes, now: now,
            currentMode: mode, wasSnappedToNote: wasSnappedToNote,
            previousSelectedMinute: previousSelectedMinute
        )
        mode = resolution.mode
        manualProgress = resolution.progress
        wasSnappedToNote = resolution.isSnappedToNote
        previousSelectedMinute = resolution.selectedMinute
        lastInteractionAt = now
    }

    func resumeLive() {
        mode = .live
        wasSnappedToNote = false
        lastInteractionAt = nil
    }

    /// Called from the clock leaf: a manual track left idle goes back live.
    func tick(now: Date) {
        if calendarEventTimelineShouldAutoResumeLive(mode: mode, lastInteractionAt: lastInteractionAt, now: now),
           !isComposing {
            resumeLive()
        }
    }

    // MARK: - Composer

    func beginAdding(now: Date) {
        editingNoteID = nil
        flushCreatedNoteID = nil
        draftText = ""
        existingImages = []
        imageDrafts = []
        isComposing = true
        lastInteractionAt = now
    }

    func beginEditing(_ note: EventLogTimelineNote, now: Date) {
        editingNoteID = note.id
        flushCreatedNoteID = nil
        draftText = note.text
        existingImages = note.images
        imageDrafts = []
        isComposing = true
        lastInteractionAt = now
    }

    func cancel() {
        isComposing = false
        editingNoteID = nil
        flushCreatedNoteID = nil
        draftText = ""
        existingImages = []
        imageDrafts = []
    }

    func addImage(data: Data) {
        guard imageCount < Self.maxImages else { return }
        imageDrafts.append(ImageDraft(id: UUID(), data: data))
    }

    func removeExistingImage(_ id: UUID) { existingImages.removeAll { $0.id == id } }
    func removeImageDraft(_ id: UUID) { imageDrafts.removeAll { $0.id == id } }

    var canSave: Bool {
        !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || imageCount > 0
    }

    /// Save: a new note lands at the track's instant (live = now, manual =
    /// the scrubbed time); an edited note keeps its time. The phone's
    /// saveTimelineNote(at:).
    func save(now: Date, range: Event.TimeRange?) {
        guard canSave else { return }
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = importDrafts()
        if let editingNoteID {
            store.updateTimelineNote(editingNoteID, text: text, images: images, for: occurrence)
        } else {
            let at = range.map { resolvedState(now: now, range: $0).snapshotDate } ?? now
            store.appendTimelineNote(text, createdAt: at, source: "macInspector",
                                     images: images, for: occurrence)
        }
        cancel()
    }

    /// The pane is going away with a draft open: keep it as a note rather
    /// than drop what was typed. Editing an existing note never commits a
    /// half-edit (only a note this flush created is updated). The phone's
    /// flushTimelineNoteDraft.
    func flush(now: Date, range: Event.TimeRange?) {
        guard isComposing, canSave else { return }
        if let editingID = editingNoteID, editingID != flushCreatedNoteID { return }
        guard store.findCalendarEvent(id: occurrence.eventID) != nil else { return }
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = importDrafts()
        if let editingNoteID {
            store.updateTimelineNote(editingNoteID, text: text, images: images, for: occurrence)
        } else {
            let id = UUID()
            let at = range.map { resolvedState(now: now, range: $0).snapshotDate } ?? now
            store.appendTimelineNote(text, id: id, createdAt: at, source: "macInspector",
                                     images: images, for: occurrence)
            editingNoteID = id
            flushCreatedNoteID = id
        }
        existingImages = images
    }

    func delete(_ note: EventLogTimelineNote) {
        store.deleteTimelineNote(note.id, for: occurrence)
        if editingNoteID == note.id { cancel() }
    }

    func imageURL(_ ref: AgenticIntakeImageRef) -> URL { assets.absoluteURL(for: ref) }

    /// Import the picked files once; they become existing refs after.
    private func importDrafts() -> [AgenticIntakeImageRef] {
        var saved = existingImages
        if !imageDrafts.isEmpty {
            let imported = imageDrafts.map { AgenticIntakeAssetStore.ImportedImage(id: $0.id, data: $0.data) }
            if let refs = try? assets.saveImages(imported, for: occurrence.eventID) {
                saved.append(contentsOf: refs)
            }
            imageDrafts = []
        }
        existingImages = saved
        return saved
    }
}
