//
//  ReportStatsBuilder.swift
//  Done
//
//  Pure statistics layer for the generative report system (Discussion #111).
//
//  Turns a flat array of `Event`s into a `ReportStats` payload.  The whole
//  computation is a pure function of its inputs:
//
//    * No `Date()` / "now" anywhere on the calculation path — the window is
//      fully described by `start`/`end`, and occurrences are expanded from the
//      events' own `timeRanges` (a live `timerStartedAt` range is deliberately
//      ignored; it isn't a committed record yet and reading it would mean
//      touching the wall-clock).
//    * No `EventStore` / `@MainActor` / global mutable state — inputs are value
//      types, output is a value type, so `build` can run on a background thread.
//
//  Dataset contract: the caller is expected to pass the SAME set the Analysis
//  charts feed on — `EventStore.canvasRenderableCalendarEvents` (raw calendar
//  events minus absorbed todos).  A report and a chart shown on the same screen
//  must never disagree, so the SET must match; feeding raw events would
//  double-count an absorbed todo against its parent's window.  The hour
//  ACCOUNTING must match too: hour totals here run through the same
//  overlap-sharing sweep the Analysis charts use (`Event.overlapSharedHours`,
//  #116), so a window covered by n occurrences credits each 1/n on both
//  surfaces.  `build` itself does not know about the store — enforcing the
//  right set is the call site's job (mirroring
//  `AnalysisViewModel.typeAllocations`).
//
//  `events` may contain occurrences outside the window (the caller filters
//  coarsely); `build` filters precisely to `[start, end)` and reuses the same
//  array to compute the previous equal-length window `[start - length, start)`
//  as a comparison baseline.
//

import Foundation

enum ReportStatsBuilder {

    // A single expanded occurrence — one event's time range on the timeline.
    // Recurring series are expanded into these per matching day; single events
    // contribute their committed `timeRanges`.  Mirrors
    // `CalendarLayout.EventOccurrence` but built here without the timer/`Date()`
    // branch so the computation stays wall-clock-free.  Internal (not private)
    // because `ReportClueBuilder` runs its detectors over the same expansion —
    // every clue figure must come from the same aggregation primitives as the
    // DATA block (#116 discipline: no consumer computes hours its own way).
    struct Occurrence {
        let event: Event
        let range: Event.TimeRange
    }

    // MARK: - Entry point

    static func build(
        events: [Event],
        start: Date,
        end: Date,
        calendar: Calendar
    ) -> ReportStats {
        let length = end.timeIntervalSince(start)
        let previousStart = start.addingTimeInterval(-length)

        // Expand once over the union of both windows, then slice per window.
        let allOccurrences = expandOccurrences(
            events: events,
            windowStart: previousStart,
            windowEnd: end,
            calendar: calendar
        )
        let currentOccurrences = allOccurrences.filter {
            $0.range.end > start && $0.range.start < end
        }
        let previousOccurrences = allOccurrences.filter {
            $0.range.end > previousStart && $0.range.start < start
        }

        let days = calendarDays(from: start, to: end, calendar: calendar)

        // --- Window metadata --------------------------------------------------
        let recordedDays = days.filter { day in
            currentOccurrences.contains { occ in
                occ.range.end > calendar.startOfDay(for: day)
                    && occ.range.start < dayEnd(day, calendar)
            }
        }
        let eventIDs = Set(currentOccurrences.map { $0.event.id })
        // Thin is kind-aware (#111 panel, Slice A hard prerequisite): a daily
        // window can never reach thinMinRecordedDays=4, so the old rule marked
        // EVERY daily report sparse and told the model to keep it to a few
        // sentences — colliding with the clue battery.  For a single-day
        // window, thin means "nothing recorded today"; multi-day windows keep
        // the original floor.
        let isThin: Bool
        if days.count <= 1 {
            isThin = recordedDays.isEmpty
        } else {
            isThin = recordedDays.count < ReportTuning.thinMinRecordedDays
                || eventIDs.count < ReportTuning.thinMinEvents
        }
        let meta = ReportWindowMeta(
            start: start,
            end: end,
            dayCount: days.count,
            recordedDayCount: recordedDays.count,
            eventCount: eventIDs.count,
            isThin: isThin
        )

        // --- perTypeHours (split-at-midnight, weight-distributed) ------------
        let currentTypeHours = weightedTypeHours(
            occurrences: currentOccurrences, days: days, calendar: calendar
        )
        let previousDays = calendarDays(from: previousStart, to: start, calendar: calendar)
        let previousTypeHours = weightedTypeHours(
            occurrences: previousOccurrences, days: previousDays, calendar: calendar
        )
        let perTypeHours = makeTypeHours(
            current: currentTypeHours,
            previous: previousTypeHours,
            isThin: meta.isThin
        )

        // --- dailyTotals (split-at-midnight, matches the chart) --------------
        let dailyTotals = days.map { day in
            ReportDailyTotal(
                date: day,
                hours: netClampedTotalHours(occurrences: currentOccurrences, on: day, calendar: calendar)
            )
        }

        // --- sessionDaily (whole-occurrence attribution, cross-midnight fixed)
        let sessionDaily = weightedSessionDaily(
            occurrences: currentOccurrences, calendar: calendar
        )

        // --- typePairRelations (top-N by total hours) ------------------------
        let typePairRelations = makePairRelations(
            perTypeHours: perTypeHours,
            sessionDaily: sessionDaily,
            recordedDays: recordedDays
        )

        // --- timeOfDayShares --------------------------------------------------
        let timeOfDayShares = makeTimeOfDayShares(
            occurrences: currentOccurrences, calendar: calendar
        )

        return ReportStats(
            window: meta,
            perTypeHours: perTypeHours,
            dailyTotals: dailyTotals,
            sessionDaily: sessionDaily,
            typePairRelations: typePairRelations,
            timeOfDayShares: timeOfDayShares
        )
    }

    // MARK: - Backfill detection (edit-awareness trigger)

    /// Gross hours and count of occurrences that fall inside `[start, end)` yet
    /// belong to events *created after* `after` — the backfill signal for the
    /// memory block's "prior window reads fuller now" hint (edit awareness).
    ///
    /// The only signal is `Event.createdAt`, an existing field, so this is
    /// asymmetric *by construction*: it can only ever count records ADDED since
    /// `after`, never ones deleted or edited.  That mechanical asymmetry is the
    /// point — it keeps the forgotten-record red line (deletions/edits are never
    /// narrated) without relying on a rule the model has to obey, and it avoids
    /// the rejected symmetric stats-diff (builder drift would slander history).
    ///
    /// `hours` is the RAW overlap of each late occurrence with the window — no
    /// interrupt netting, no type-weight split.  This is a *trigger* number, not
    /// one shown to anyone (backfill surfaces no count and no delta), so the
    /// cheap gross figure is deliberate.  `occurrences` is how many such
    /// occurrences overlap the window.
    ///
    /// Pure like the rest of the builder: no `Date()`, no store — `after` is
    /// injected by the caller (a prior report's `createdAt`).
    static func backfilledSince(
        events: [Event],
        start: Date,
        end: Date,
        after: Date,
        calendar: Calendar
    ) -> (hours: Double, occurrences: Int) {
        let occurrences = expandOccurrences(
            events: events, windowStart: start, windowEnd: end, calendar: calendar
        )
        .filter { $0.range.end > start && $0.range.start < end && $0.event.createdAt > after }
        var hours = 0.0
        for occ in occurrences {
            let s = max(occ.range.start, start)
            let e = min(occ.range.end, end)
            if e > s { hours += e.timeIntervalSince(s) / 3600 }
        }
        return (hours, occurrences.count)
    }

    // MARK: - Event detail serialization

    /// Serializes the window's individual records for the prompt's EVENTS
    /// block — the texture (titles, notes) that lets the report reference
    /// specific moments instead of speaking only in category totals.  Numbers
    /// remain the DATA block's job; this block is quotable specifics.
    ///
    /// Chronological, one block per occurrence.  The header is one line:
    /// `EVENT Mon 2026-06-29 09:00–12:00 [type] title — note` (note flattened
    /// and clipped to `ReportTuning.maxNoteChars`).  A `.todo` occurrence leads
    /// with `TODO` instead and carries a `(open)`/`(done)` completion marker
    /// before the `[type]` — its time is a calendar placement, not spent time.
    /// When the occurrence has a
    /// log and/or feedback record, indented sub-lines follow carrying what the
    /// person actually wrote — the highest-value material in the whole block:
    ///
    ///     EVENT …
    ///       LOG completed 55min effort 4/5 [focused,tired] summary — note
    ///       Focus Quality=4/5
    ///       NOTE ran into a wall on the parser [photo]
    ///       FELT effort 3/5 [stressed] — glad it's over
    ///
    /// Records are matched to occurrences by `CalendarOccurrenceKey` (the same
    /// derivation the app writes with — `make(for:occurrenceDate:)`); an
    /// occurrence with no matching record has no sub-lines, exactly as before.
    /// All-day events are excluded.  A record-bearing occurrence is high
    /// information, so it is never folded into a recurring-series collapse line
    /// — only the recordless occurrences of a series collapse.  When the budget
    /// runs out the tail (whole blocks, sub-lines never split from their header)
    /// is dropped and a final line states how many records were omitted.
    ///
    /// `attachableImageIDs` is the set of note-image ids the service has already
    /// verified as readable on disk and is willing to attach to a vision
    /// request.  When it is empty (the default) nothing is attached and every
    /// photo keeps the indexless `[photo]`/`[N photos]` marker — identical to
    /// the pre-vision behaviour.  When non-empty, the serializer, in the SAME
    /// pass that emits the marker, assigns each attachable image (in occurrence
    /// time order, up to `ReportTuning.maxReportPhotos`) the next 1-based index,
    /// writes `[photo #k]`, and appends its ref to
    /// `ReportEventsBlock.attachedImageRefs` — so the marker and the returned
    /// array cannot drift apart.  Budget truncation only ever drops a
    /// contiguous tail of blocks, so the surviving `[photo #k]` markers remain a
    /// contiguous prefix aligned with the refs kept for those same blocks.
    static func promptEvents(
        events: [Event],
        start: Date,
        end: Date,
        calendar: Calendar,
        budget: Int,
        logRecords: [CalendarEventLogRecord] = [],
        feedbackRecords: [CalendarEventFeedbackRecord] = [],
        attachableImageIDs: Set<UUID> = []
    ) -> ReportEventsBlock {
        let empty = ReportEventsBlock(text: "", attachedImageRefs: [])
        guard budget > 0 else { return empty }
        let occurrences = expandOccurrences(
            events: events, windowStart: start, windowEnd: end, calendar: calendar
        )
        .filter { $0.range.end > start && $0.range.start < end }
        .sorted { $0.range.start < $1.range.start }
        guard !occurrences.isEmpty else { return empty }

        // Record lookup keyed by the occurrence key the app itself writes.
        // Duplicate keys (e.g. two edits racing) keep the last seen — the
        // arrays already hold at most one record per occurrence in practice.
        let logByKey = Dictionary(logRecords.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        let feedbackByKey = Dictionary(feedbackRecords.map { ($0.id, $0) }, uniquingKeysWith: { $1 })

        // Annotate each occurrence with its matched records once (the key
        // derivation is the authoritative `make`, so matching stays in lock-step
        // with how the records were stored — no re-implemented predicate to drift).
        let annotated: [(occ: Occurrence, log: CalendarEventLogRecord?, feedback: CalendarEventFeedbackRecord?)] =
            occurrences.map { occ in
                let key = CalendarOccurrenceKey.make(for: occ.event, occurrenceDate: occ.range.start)
                return (occ, logByKey[key], feedbackByKey[key])
            }

        // Model-facing formatting: fixed POSIX locale so the block is stable
        // regardless of device locale; the passed calendar keeps day/time
        // boundaries consistent with the DATA block.
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.calendar = calendar
        dayFormatter.timeZone = calendar.timeZone
        dayFormatter.dateFormat = "EEE yyyy-MM-dd"
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.calendar = calendar
        timeFormatter.timeZone = calendar.timeZone
        timeFormatter.dateFormat = "HH:mm"

        func header(_ occ: Occurrence, recurringCount: Int?) -> String {
            // A `.todo` is an intent, not a record of time spent: its time range
            // is only where it sits on the calendar (plan/placement), so it leads
            // with TODO instead of EVENT and carries a completion marker —
            // `(open)` still-hanging vs `(done)` actually finished (Event.isDone,
            // the explicit-completion flag from the calendar-todo design).  A todo
            // recurring series collapses through this same header, so the marker
            // and prefix ride along on its count line too.
            let isTodo = occ.event.kind == .todo
            var line = "\(isTodo ? "TODO" : "EVENT") \(dayFormatter.string(from: occ.range.start)) "
                + "\(timeFormatter.string(from: occ.range.start))–\(timeFormatter.string(from: occ.range.end)) "
            if isTodo {
                line += occ.event.isDone ? "(done) " : "(open) "
            }
            line += "[\(occ.event.type.isEmpty ? "Other" : occ.event.type)] \(occ.event.title)"
            if let recurringCount, recurringCount > 1 {
                line += " (recurring, ×\(recurringCount) this period)"
            }
            let note = flattenRecordText(occ.event.note)
            if !note.isEmpty {
                line += " — \(note.prefix(ReportTuning.maxNoteChars))"
            }
            return line
        }

        // A recordless recurring series would repeat an identical low-information
        // header once per day and crowd the budget — so its recordless
        // occurrences collapse to one line carrying their count.  Occurrences
        // that DO carry a record are surfaced individually below.
        var seriesRecordlessCount: [UUID: Int] = [:]
        for entry in annotated where entry.occ.event.isRecurringSeries {
            if entry.log == nil && entry.feedback == nil {
                seriesRecordlessCount[entry.occ.event.id, default: 0] += 1
            }
        }

        // One running assignment shared across every block: image ids are
        // numbered in occurrence order, so the `[photo #k]` markers and
        // `assignment.refs` grow together (see `PhotoAssignment`).  Each block
        // records the slice of refs it contributed so the budget pass below can
        // keep refs and markers in lock-step.
        var assignment = PhotoAssignment(
            attachableImageIDs: attachableImageIDs,
            maxPhotos: ReportTuning.maxReportPhotos
        )

        var entries: [ReportEventsBlock] = []
        var seriesCollapsed: Set<UUID> = []
        for entry in annotated {
            let occ = entry.occ
            let hasRecord = entry.log != nil || entry.feedback != nil
            if occ.event.isRecurringSeries && !hasRecord {
                // Emit the series' collapse line once, at its first recordless
                // occurrence in chronological order.  Collapse lines carry no
                // records, so they never attach a photo.
                guard seriesCollapsed.insert(occ.event.id).inserted else { continue }
                let count = seriesRecordlessCount[occ.event.id] ?? 0
                guard count > 0 else { continue }
                entries.append(ReportEventsBlock(text: header(occ, recurringCount: count), attachedImageRefs: []))
                continue
            }
            // Single events, and record-bearing recurring occurrences, surface
            // as their own block (concrete date already disambiguates them).
            let refsBefore = assignment.refs.count
            let block = ([header(occ, recurringCount: nil)]
                + recordSubLines(log: entry.log, feedback: entry.feedback, assignment: &assignment))
                .joined(separator: "\n")
            entries.append(ReportEventsBlock(
                text: block,
                attachedImageRefs: Array(assignment.refs[refsBefore...])
            ))
        }

        let budgetChars = budget * ReportTuning.charsPerToken
        var blocks: [String] = []
        var attachedImageRefs: [AgenticIntakeImageRef] = []
        var usedChars = 0
        for entry in entries {
            // A block is charged whole (header + its sub-lines) so a record's
            // sub-lines are never split from the header they belong to.  Kept
            // blocks are a contiguous prefix (the loop breaks, never skips), so
            // the refs accumulated here stay a prefix of `assignment.refs` —
            // exactly the `[photo #1..k]` markers surviving in the text.
            guard usedChars + entry.text.count + 1 <= budgetChars else { break }
            blocks.append(entry.text)
            attachedImageRefs.append(contentsOf: entry.attachedImageRefs)
            usedChars += entry.text.count + 1
        }
        let omitted = entries.count - blocks.count
        if omitted > 0 {
            blocks.append("(+\(omitted) more records omitted for length)")
        }
        return ReportEventsBlock(
            text: blocks.joined(separator: "\n"),
            attachedImageRefs: attachedImageRefs
        )
    }

    // MARK: - Photo attachment bookkeeping

    // Single source of truth for the report's photo indexing.  The serializer
    // holds one instance while walking occurrences in time order; each
    // attachable image (in `attachableImageIDs`, under the `maxPhotos` cap) is
    // appended here and takes its 1-based array position as its `[photo #k]`
    // index.  Because the index IS the array position, a marker and its image
    // are assigned in the same statement and cannot fall out of alignment.
    private struct PhotoAssignment {
        let attachableImageIDs: Set<UUID>
        let maxPhotos: Int
        var refs: [AgenticIntakeImageRef] = []
        private var indexByID: [UUID: Int] = [:]

        init(attachableImageIDs: Set<UUID>, maxPhotos: Int) {
            self.attachableImageIDs = attachableImageIDs
            self.maxPhotos = maxPhotos
        }

        // Attaches `image` and returns its 1-based index, or nil when it is not
        // attachable (vision off / not preloaded) or the cap is already full —
        // in which case the caller keeps the indexless `[photo]` marker.  A
        // photo seen before (the same record surfacing in more than one
        // occurrence block, e.g. a multi-range event) reuses its existing
        // index instead of attaching a duplicate.  Reuse can only happen in a
        // LATER block than the first assignment, so budget truncation's
        // contiguous-prefix rule still guarantees any surviving `[photo #k]`
        // has its image attached.
        mutating func assign(_ image: AgenticIntakeImageRef) -> Int? {
            if let existing = indexByID[image.id] { return existing }
            guard attachableImageIDs.contains(image.id), refs.count < maxPhotos else { return nil }
            refs.append(image)
            indexByID[image.id] = refs.count
            return refs.count
        }
    }

    // MARK: - Record sub-line serialization

    // Indented LOG/FELT/NOTE/answer sub-lines for one occurrence's matched
    // records.  Each is a single logical line (all text fields flattened via
    // `\R` and clipped) so the one-line-per-record contract of the block
    // survives; the whole set is capped at `maxRecordSubLines` so a
    // journaling-heavy event can't swallow the budget.
    private static func recordSubLines(
        log: CalendarEventLogRecord?,
        feedback: CalendarEventFeedbackRecord?,
        assignment: inout PhotoAssignment
    ) -> [String] {
        var lines: [String] = []
        if let log {
            if let logLine = makeLogLine(log) { lines.append(logLine) }
            lines.append(contentsOf: templateAnswerLines(log))
            lines.append(contentsOf: timelineNoteLines(log, assignment: &assignment))
        }
        if let feedback {
            if let feltLine = makeFeltLine(feedback) { lines.append(feltLine) }
            lines.append(contentsOf: feedbackLogLines(feedback))
        }
        guard lines.count > ReportTuning.maxRecordSubLines else { return lines }
        let keep = ReportTuning.maxRecordSubLines - 1
        let more = lines.count - keep
        return Array(lines.prefix(keep)) + ["  (+\(more) more record lines)"]
    }

    // `LOG completed 55min effort 4/5 [focused,tired] summary — note`.  Only the
    // fields that are present appear; if the whole record is empty, no LOG line.
    private static func makeLogLine(_ record: CalendarEventLogRecord) -> String? {
        var parts = ["LOG"]
        if let status = record.completionStatus { parts.append(status.rawValue) }
        if let minutes = record.actualDurationMinutes { parts.append("\(minutes)min") }
        if let effort = record.effort { parts.append("effort \(effort)/5") }
        let tags = record.emotions + record.behaviors
        if !tags.isEmpty { parts.append("[\(tags.joined(separator: ","))]") }
        var textBits: [String] = []
        let summary = clipRecordText(record.summary)
        if !summary.isEmpty { textBits.append(summary) }
        let note = clipRecordText(record.note)
        if !note.isEmpty { textBits.append(note) }
        guard parts.count > 1 || !textBits.isEmpty else { return nil }
        var line = "  " + parts.joined(separator: " ")
        if !textBits.isEmpty { line += " " + textBits.joined(separator: " — ") }
        return line
    }

    // `  Focus Quality=4/5` — field id translated to its template title (raw id
    // if the template/field is unknown), rating values shown as `n/5`, and
    // single/multi-select option ids translated to their human titles.
    private static func templateAnswerLines(_ record: CalendarEventLogRecord) -> [String] {
        let templateID = (record.selectedTemplateID ?? record.suggestedTemplateID)
            .flatMap(EventLogTemplateID.init(rawValue:))
        // Deterministic order — the dictionary itself is unordered.
        return record.templateAnswers.sorted { $0.key < $1.key }.map { fieldID, value in
            let title = templateID
                .flatMap { EventLogTemplateRegistry.fieldTitle(templateID: $0, fieldID: fieldID) }
                ?? fieldID
            let rendered = renderAnswer(value, templateID: templateID, fieldID: fieldID)
            return "  \(title)=\(rendered)"
        }
    }

    private static func renderAnswer(
        _ value: EventLogAnswerValue,
        templateID: EventLogTemplateID?,
        fieldID: String
    ) -> String {
        switch value {
        case .int(let n):
            let isRating = templateID
                .flatMap { EventLogTemplateRegistry.definition(for: $0)?.fields.first { $0.id == fieldID }?.kind } == .rating
            return isRating ? "\(n)/5" : "\(n)"
        case .string(let raw):
            let mapped = templateID
                .flatMap { EventLogTemplateRegistry.optionTitle(templateID: $0, fieldID: fieldID, optionID: raw) }
                ?? raw
            return clipRecordText(mapped)
        case .strings(let raws):
            let mapped = raws.map { raw in
                templateID
                    .flatMap { EventLogTemplateRegistry.optionTitle(templateID: $0, fieldID: fieldID, optionID: raw) }
                    ?? raw
            }
            return clipRecordText(mapped.joined(separator: ","))
        }
    }

    // `  NOTE <text> — <meal description> [photo #k]`.  The meal description is
    // the AI text already materialized at write time.  A photo's marker is
    // `[photo #k]` when the serializer attaches the image to the request (see
    // `PhotoAssignment`) and the indexless `[photo]`/`[N photos]` otherwise —
    // the latter only signalling a picture existed without travelling.
    private static func timelineNoteLines(
        _ record: CalendarEventLogRecord,
        assignment: inout PhotoAssignment
    ) -> [String] {
        var lines: [String] = []
        for item in record.timelineItems {
            guard case .note(let note) = item else { continue }
            var pieces: [String] = []
            let text = clipRecordText(note.text)
            if !text.isEmpty { pieces.append(text) }
            if let meal = note.mealAnalysis {
                let desc = String(mealDescription(meal).prefix(ReportTuning.maxRecordFieldChars))
                if !desc.isEmpty { pieces.append(desc) }
            }
            let content = pieces.joined(separator: " — ")
            guard !content.isEmpty || !note.images.isEmpty else { continue }
            var line = "  NOTE"
            if !content.isEmpty { line += " " + content }
            line += photoMarker(for: note.images, assignment: &assignment)
            lines.append(line)
        }
        return lines
    }

    // The trailing photo marker for one note's images.  Attachable, under-cap
    // images each get their own `[photo #k]` (assigned + collected in the same
    // step); the rest fold into a single trailing indexless `[photo]`/`[N
    // photos]`.  Empty when the note has no images.
    private static func photoMarker(
        for images: [AgenticIntakeImageRef],
        assignment: inout PhotoAssignment
    ) -> String {
        guard !images.isEmpty else { return "" }
        var parts: [String] = []
        var plainCount = 0
        for image in images {
            if let index = assignment.assign(image) {
                parts.append("[photo #\(index)]")
            } else {
                plainCount += 1
            }
        }
        if plainCount > 0 {
            parts.append(plainCount == 1 ? "[photo]" : "[\(plainCount) photos]")
        }
        return " " + parts.joined(separator: " ")
    }

    private static func mealDescription(_ meal: MealPhotoAnalysis) -> String {
        var bits: [String] = []
        if !meal.items.isEmpty { bits.append(meal.items.joined(separator: ", ")) }
        if !meal.verdict.isEmpty { bits.append(meal.verdict) }
        if !meal.suggestion.isEmpty { bits.append(meal.suggestion) }
        var text = bits.joined(separator: "; ")
        if meal.calories > 0 {
            text += text.isEmpty ? "\(meal.calories) kcal" : " (\(meal.calories) kcal)"
        }
        return flattenRecordText(text)
    }

    // `  FELT effort 3/5 [stressed] — selfNote`.  Empty record → no FELT line.
    private static func makeFeltLine(_ record: CalendarEventFeedbackRecord) -> String? {
        var parts = ["FELT"]
        if let effort = record.effort { parts.append("effort \(effort)/5") }
        let tags = record.emotions + record.behaviors
        if !tags.isEmpty { parts.append("[\(tags.joined(separator: ","))]") }
        let selfNote = clipRecordText(record.selfNote)
        guard parts.count > 1 || !selfNote.isEmpty else { return nil }
        var line = "  " + parts.joined(separator: " ")
        if !selfNote.isEmpty { line += " — " + selfNote }
        return line
    }

    private static func feedbackLogLines(_ record: CalendarEventFeedbackRecord) -> [String] {
        record.logs.compactMap { entry in
            let text = clipRecordText(entry.text)
            return text.isEmpty ? nil : "  NOTE " + text
        }
    }

    // `\R` covers \n, \r\n, \r, and the Unicode line/paragraph separators —
    // anything that would break the one-line-per-record contract.
    private static func flattenRecordText(_ text: String) -> String {
        text.replacingOccurrences(of: "\\R", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Internal: the evidence packs clip their QUOTE text through the same rule.
    static func clipRecordText(_ text: String) -> String {
        String(flattenRecordText(text).prefix(ReportTuning.maxRecordFieldChars))
    }

    // MARK: - Occurrence expansion

    // Expands events into occurrences overlapping `[windowStart, windowEnd)`.
    // All-day events are skipped (they carry no time-of-day duration), and the
    // live-timer range is ignored — see the file header for why.  Internal so
    // the clue battery expands its lookback history through the same path.
    static func expandOccurrences(
        events: [Event],
        windowStart: Date,
        windowEnd: Date,
        calendar: Calendar
    ) -> [Occurrence] {
        var result: [Occurrence] = []
        for event in events {
            if event.isAllDay { continue }

            if event.isRecurringSeries {
                // Walk each day in the union window and ask the shared
                // recurrence helper (which is itself wall-clock-free).
                var day = calendar.startOfDay(for: windowStart)
                let lastDay = calendar.startOfDay(for: windowEnd)
                while day <= lastDay {
                    if let range = CalendarLayout.recurrenceOccurrence(for: event, on: day, calendar: calendar),
                       range.end > windowStart, range.start < windowEnd {
                        result.append(Occurrence(event: event, range: range))
                    }
                    guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                    day = next
                }
                continue
            }

            for range in event.timeRanges where range.end > windowStart && range.start < windowEnd {
                result.append(Occurrence(event: event, range: range))
            }
        }
        return result
    }

    // MARK: - Interrupt netting + overlap sharing (parity with AnalysisViewModel)

    // Ranges of embedded interrupt children keyed by their parent event id.
    // Interrupt children surface as their own occurrences (under their own
    // type), so their time is subtracted from the parent to keep total
    // wall-clock conserved — same decision as `AnalysisViewModel`.
    static func interruptChildRanges(
        _ occurrences: [Occurrence]
    ) -> [UUID: [Event.TimeRange]] {
        var map: [UUID: [Event.TimeRange]] = [:]
        for occ in occurrences {
            guard let relation = occ.event.interruptRelation,
                  relation.state == .embedded else { continue }
            map[relation.parentEventID, default: []].append(occ.range)
        }
        return map
    }

    // Per-occurrence net hours on `day` under overlap sharing: each range is
    // clamped to the day and its embedded interrupt children cut out (merged
    // once), then a window covered by n remaining occurrences credits each
    // 1/n — the same `Event.overlapSharedHours` sweep the Analysis charts run
    // (#116), so the report and a chart on the same screen agree on a day's
    // hours.  Result pairs are aligned with the occurrences that survived
    // clamping.
    private static func overlapSharedDayHours(
        occurrences: [Occurrence],
        childRanges: [UUID: [Event.TimeRange]],
        on day: Date,
        calendar: Calendar
    ) -> [(occurrence: Occurrence, hours: Double)] {
        overlapSharedWindowHours(
            occurrences: occurrences,
            childRanges: childRanges,
            windowStart: calendar.startOfDay(for: day),
            windowEnd: dayEnd(day, calendar)
        )
    }

    // The window-generic core of the sharing pass — the day variant above and
    // the clue battery's elapsed-clamped sub-windows both run through it.
    private static func overlapSharedWindowHours(
        occurrences: [Occurrence],
        childRanges: [UUID: [Event.TimeRange]],
        windowStart: Date,
        windowEnd: Date
    ) -> [(occurrence: Occurrence, hours: Double)] {
        var kept: [Occurrence] = []
        var contributions: [[Event.TimeRange]] = []
        for occ in occurrences {
            let intervals = Event.remainingIntervals(
                occ.range,
                excluding: childRanges[occ.event.id] ?? [],
                windowStart: windowStart,
                windowEnd: windowEnd
            )
            guard !intervals.isEmpty else { continue }
            kept.append(occ)
            contributions.append(intervals)
        }
        let shared = Event.overlapSharedHours(contributions: contributions)
        return zip(kept, shared).map { (occurrence: $0.0, hours: $0.1) }
    }

    // Overlap-shared, weight-distributed per-type hours over one continuous
    // sub-window — the clue battery's aggregation entry.  Identical accounting
    // to `weightedTypeHours` (which clamps to whole days), so a clue's "today"
    // figure and the DATA block's CATEGORY figure can never disagree.
    static func sharedWeightedTypeHours(
        occurrences: [Occurrence],
        windowStart: Date,
        windowEnd: Date
    ) -> [String: Double] {
        let childRanges = interruptChildRanges(occurrences)
        var hoursByType: [String: Double] = [:]
        for (occ, net) in overlapSharedWindowHours(
            occurrences: occurrences, childRanges: childRanges,
            windowStart: windowStart, windowEnd: windowEnd
        ) {
            guard net > 0 else { continue }
            for (type, weight) in normalizedTypeWeights(for: occ.event) {
                hoursByType[type, default: 0] += net * weight
            }
        }
        return hoursByType
    }

    // Whole-occurrence net hours (not clamped to any day) after subtracting
    // embedded interrupt children — used by the session (whole-attribution)
    // aggregation.
    private static func netWholeHours(
        _ occurrence: Occurrence,
        childRanges: [Event.TimeRange]
    ) -> Double {
        Event.interruptedDuration(
            parentRange: occurrence.range,
            childRanges: childRanges
        ).netSeconds / 3600
    }

    // MARK: - Type-weight distribution

    // Normalized (type, weight) pairs summing to 1 for one event, applying the
    // documented `effectiveTypeWeights` semantics: `typeWeights == nil` splits
    // equally across `effectiveTypes`; otherwise each type takes its listed
    // weight (clamped to ≥ 0), a type missing from the dict falls back to the
    // mean of the provided weights, and the result is renormalized.  (The
    // canonical `Event.effectiveTypeWeights` helper is referenced in comments
    // on `Event` but not yet implemented, so the semantics live here for now.)
    //
    // Empty type strings collapse to the same "Other" bucket the Analysis chart
    // uses, so single-category numbers line up with `typeAllocations`.
    static func normalizedTypeWeights(for event: Event) -> [(type: String, weight: Double)] {
        let types = event.effectiveTypes.map { $0.isEmpty ? "Other" : $0 }
        guard types.count > 1 else {
            return [(types.first ?? "Other", 1.0)]
        }
        guard let weights = event.typeWeights, !weights.isEmpty else {
            let equal = 1.0 / Double(types.count)
            return types.map { ($0, equal) }
        }
        let provided = event.effectiveTypes.compactMap { weights[$0] }.filter { $0 >= 0 }
        let fallback = provided.isEmpty ? 1.0 : provided.reduce(0, +) / Double(provided.count)
        let raw = event.effectiveTypes.map { max(0, weights[$0] ?? fallback) }
        let sum = raw.reduce(0, +)
        guard sum > 0 else {
            let equal = 1.0 / Double(types.count)
            return types.map { ($0, equal) }
        }
        return zip(types, raw).map { ($0, $1 / sum) }
    }

    // MARK: - Aggregations

    // Per-type total hours over `days`: split at midnight, overlap-shared (a
    // window covered by n occurrences credits each 1/n — parity with the
    // Analysis charts, #116), and distributed across an event's types by
    // weight.  This is the report's counterpart to the chart's
    // `typeAllocations`; it diverges only for multi-type events (the
    // experimental feature), where the chart still counts primary-type-only.
    private static func weightedTypeHours(
        occurrences: [Occurrence],
        days: [Date],
        calendar: Calendar
    ) -> [String: Double] {
        var hoursByType: [String: Double] = [:]
        let childRanges = interruptChildRanges(occurrences)
        for day in days {
            for (occ, net) in overlapSharedDayHours(
                occurrences: occurrences, childRanges: childRanges, on: day, calendar: calendar
            ) {
                guard net > 0 else { continue }
                for (type, weight) in normalizedTypeWeights(for: occ.event) {
                    hoursByType[type, default: 0] += net * weight
                }
            }
        }
        return hoursByType
    }

    // Day's total scheduled hours (all types), split at midnight and
    // overlap-shared — the summed shares equal the union coverage, the value
    // `dailyTotals` and `AnalysisViewModel.totalScheduledHours` agree on
    // (#116); a day can no longer exceed 24h through parallel events.
    private static func netClampedTotalHours(
        occurrences: [Occurrence],
        on day: Date,
        calendar: Calendar
    ) -> Double {
        let childRanges = interruptChildRanges(occurrences)
        return overlapSharedDayHours(
            occurrences: occurrences, childRanges: childRanges, on: day, calendar: calendar
        )
        .reduce(0.0) { $0 + $1.hours }
    }

    // Whole-occurrence per-type per-day hours: an occurrence lands entirely on
    // the day it overlaps more (ties go to the end day), so a cross-midnight
    // session isn't torn into a fake two-day pattern before the relationship
    // math sees it.
    //
    // Deliberately NOT overlap-shared (#116 decision): this series feeds the
    // pair-correlation math, where genuine co-occurrence is the signal being
    // measured — two categories running in parallel should both read as fully
    // present that day.  Sharing would divide both sides by the same coverage
    // factor on exactly the overlapping days, injecting a common-mode artifact
    // into every overlapping pair's vectors.  Wall-clock conservation matters
    // for the totals (`perTypeHours` / `dailyTotals`), not for co-variation.
    private static func weightedSessionDaily(
        occurrences: [Occurrence],
        calendar: Calendar
    ) -> [ReportTypeDayHours] {
        let childRanges = interruptChildRanges(occurrences)
        var byKey: [String: Double] = [:]     // "type|dayEpoch" → hours
        var dayByEpoch: [TimeInterval: Date] = [:]
        for occ in occurrences {
            let net = netWholeHours(occ, childRanges: childRanges[occ.event.id] ?? [])
            guard net > 0 else { continue }
            let day = dominantDay(for: occ.range, calendar: calendar)
            let epoch = day.timeIntervalSince1970
            dayByEpoch[epoch] = day
            for (type, weight) in normalizedTypeWeights(for: occ.event) {
                byKey["\(type)|\(epoch)", default: 0] += net * weight
            }
        }
        return byKey.compactMap { key, hours in
            let parts = key.split(separator: "|", maxSplits: 1)
            guard parts.count == 2, let epoch = TimeInterval(parts[1]), let day = dayByEpoch[epoch] else {
                return nil
            }
            return ReportTypeDayHours(type: String(parts[0]), date: day, hours: hours)
        }
        .sorted { $0.date == $1.date ? $0.type < $1.type : $0.date < $1.date }
    }

    // Day (start-of-day) an occurrence overlaps most; ties resolve to the later
    // day.  A 23:00→07:00 session overlaps 1h on day 1 and 7h on day 2 → day 2.
    private static func dominantDay(for range: Event.TimeRange, calendar: Calendar) -> Date {
        var day = calendar.startOfDay(for: range.start)
        let lastDay = calendar.startOfDay(for: range.end)
        var bestDay = day
        var bestOverlap = -1.0
        while day <= lastDay {
            let dStart = day
            let dEnd = dayEnd(day, calendar)
            let overlap = max(0, min(range.end, dEnd).timeIntervalSince(max(range.start, dStart)))
            // `>=` so a tie prefers the later day (loop advances forward).
            if overlap >= bestOverlap {
                bestOverlap = overlap
                bestDay = day
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return bestDay
    }

    // MARK: - Pair relations

    // Correlations run over the window's *recorded* days only.  Days with no
    // record at all would enter every vector as (0, 0) and drag every pair
    // toward a spurious positive r (co-absence measures "did the user track
    // that day", not how two categories move together).  A recorded day where
    // one category is absent stays in — that's genuine signal about the pair.
    private static func makePairRelations(
        perTypeHours: [ReportTypeHours],
        sessionDaily: [ReportTypeDayHours],
        recordedDays: [Date]
    ) -> [ReportTypePairRelation] {
        let topTypes = perTypeHours
            .sorted { $0.hours > $1.hours }
            .prefix(ReportTuning.maxPairTypes)
            .map { $0.type }
        guard topTypes.count >= 2 else { return [] }

        // Dense per-type daily vectors aligned to `recordedDays`.
        let dayIndex: [TimeInterval: Int] = Dictionary(
            uniqueKeysWithValues: recordedDays.enumerated().map { ($0.element.timeIntervalSince1970, $0.offset) }
        )
        var vectors: [String: [Double]] = [:]
        for type in topTypes { vectors[type] = Array(repeating: 0, count: recordedDays.count) }
        for entry in sessionDaily where vectors[entry.type] != nil {
            if let idx = dayIndex[entry.date.timeIntervalSince1970] {
                vectors[entry.type]?[idx] += entry.hours
            }
        }

        var relations: [ReportTypePairRelation] = []
        for i in 0..<topTypes.count {
            for j in (i + 1)..<topTypes.count {
                let a = topTypes[i], b = topTypes[j]
                guard let va = vectors[a], let vb = vectors[b] else { continue }
                let r = pearson(va, vb)
                let overlapDays = zip(va, vb).filter { $0 > 0 && $1 > 0 }.count
                let consistency = signConsistency(va, vb)
                let confidence = ReportConfidenceInput(
                    overlapDays: overlapDays,
                    consistency: consistency,
                    effectSize: abs(r)
                )
                relations.append(ReportTypePairRelation(
                    typeA: a, typeB: b, correlation: r, confidence: confidence
                ))
            }
        }
        return relations.sorted { $0.confidence.effectSize > $1.confidence.effectSize }
    }

    // Cross-half-window sign agreement: split the vectors in two, take the
    // Pearson sign in each half; 1 when both halves point the same non-zero
    // direction, else 0.  Guards against a correlation that flips mid-window.
    private static func signConsistency(_ x: [Double], _ y: [Double]) -> Double {
        guard x.count >= 4 else { return 0 }
        let mid = x.count / 2
        let firstSign = pearson(Array(x[..<mid]), Array(y[..<mid])).sign01
        let secondSign = pearson(Array(x[mid...]), Array(y[mid...])).sign01
        return (firstSign != 0 && firstSign == secondSign) ? 1 : 0
    }

    private static func pearson(_ x: [Double], _ y: [Double]) -> Double {
        guard x.count == y.count, x.count >= 2 else { return 0 }
        let n = Double(x.count)
        let meanX = x.reduce(0, +) / n
        let meanY = y.reduce(0, +) / n
        var num = 0.0, denX = 0.0, denY = 0.0
        for (xi, yi) in zip(x, y) {
            let dx = xi - meanX, dy = yi - meanY
            num += dx * dy
            denX += dx * dx
            denY += dy * dy
        }
        let den = (denX * denY).squareRoot()
        return den > 0 ? num / den : 0
    }

    // MARK: - Time of day

    private static func makeTimeOfDayShares(
        occurrences: [Occurrence],
        calendar: Calendar
    ) -> [ReportTimeOfDayShare] {
        let childRanges = interruptChildRanges(occurrences)
        // type → segment → hours
        var acc: [String: [ReportTimeOfDaySegment: Double]] = [:]
        // Distinct days each type appears on — a share computed from one or
        // two days is noise dressed as precision ("reading: morning=100%"
        // from a single session), so such types are dropped below.
        var daysByType: [String: Set<Date>] = [:]
        for occ in occurrences {
            let children = childRanges[occ.event.id] ?? []
            // Net whole hours drives the total; segment split uses the raw
            // range (interrupt netting only scales the magnitude, not which
            // segment the time sits in — a small acceptable simplification).
            let net = netWholeHours(occ, childRanges: children)
            guard net > 0 else { continue }
            let segmentSeconds = segmentSeconds(for: occ.range, calendar: calendar)
            let grossSeconds = segmentSeconds.values.reduce(0, +)
            guard grossSeconds > 0 else { continue }
            let day = calendar.startOfDay(for: occ.range.start)
            for (type, weight) in normalizedTypeWeights(for: occ.event) {
                daysByType[type, default: []].insert(day)
                for (segment, seconds) in segmentSeconds {
                    let hours = net * (seconds / grossSeconds) * weight
                    acc[type, default: [:]][segment, default: 0] += hours
                }
            }
        }
        return acc.compactMap { type, segmentHours -> ReportTimeOfDayShare? in
            guard (daysByType[type]?.count ?? 0) >= ReportTuning.minTimeOfDayDays else {
                return nil
            }
            let total = segmentHours.values.reduce(0, +)
            let shares = total > 0
                ? segmentHours.mapValues { $0 / total }
                : segmentHours
            return ReportTimeOfDayShare(type: type, shares: shares)
        }
        .sorted { $0.type < $1.type }
    }

    // Seconds an occurrence spends in each day segment, summed across every day
    // it touches (a cross-midnight session contributes to segments on both days).
    private static func segmentSeconds(
        for range: Event.TimeRange,
        calendar: Calendar
    ) -> [ReportTimeOfDaySegment: Double] {
        var result: [ReportTimeOfDaySegment: Double] = [:]
        var day = calendar.startOfDay(for: range.start)
        let lastDay = calendar.startOfDay(for: range.end)
        while day <= lastDay {
            for segment in ReportTimeOfDaySegment.allCases {
                for interval in segment.hourIntervals {
                    guard let segStart = calendar.date(bySettingHour: interval.start % 24, minute: 0, second: 0, of: day),
                          let segEnd = intervalEnd(interval.end, day: day, calendar: calendar) else { continue }
                    let overlap = max(0, min(range.end, segEnd).timeIntervalSince(max(range.start, segStart)))
                    if overlap > 0 { result[segment, default: 0] += overlap }
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }

    // End of a segment interval within `day`; hour 24 means the next midnight.
    private static func intervalEnd(_ hour: Int, day: Date, calendar: Calendar) -> Date? {
        if hour >= 24 {
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))
        }
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day)
    }

    // MARK: - perTypeHours assembly

    private static func makeTypeHours(
        current: [String: Double],
        previous: [String: Double],
        isThin: Bool
    ) -> [ReportTypeHours] {
        let allTypes = Set(current.keys).union(previous.keys)
        return allTypes.map { type in
            let cur = current[type] ?? 0
            let prev = previous[type] ?? 0
            let delta = cur - prev
            let deltaPercent: Double? = prev > 0 ? (delta / prev) * 100 : nil
            return ReportTypeHours(
                type: type,
                hours: cur,
                previousHours: prev,
                deltaHours: delta,
                deltaPercent: deltaPercent,
                tier: deltaTier(current: cur, previous: prev, isThin: isThin)
            )
        }
        .sorted { $0.hours > $1.hours }
    }

    // Confidence tier for a week-over-week delta.  A category that barely
    // appears in either window is noise (`low`); otherwise the relative change
    // sets the tier, and thin windows are capped at `medium` so the wording
    // stays soft when the whole report rests on little data.
    private static func deltaTier(current: Double, previous: Double, isThin: Bool) -> ReportConfidenceTier {
        let base = max(current, previous)
        guard base >= ReportTuning.deltaNoiseFloorHours else { return .low }
        let relative = abs(current - previous) / base
        let raw: ReportConfidenceTier
        if relative >= ReportTuning.deltaHighRelative {
            raw = .high
        } else if relative >= ReportTuning.deltaMediumRelative {
            raw = .medium
        } else {
            raw = .low
        }
        return isThin ? min(raw, .medium) : raw
    }

    // MARK: - Day helpers

    private static func calendarDays(from start: Date, to end: Date, calendar: Calendar) -> [Date] {
        var days: [Date] = []
        var current = calendar.startOfDay(for: start)
        let boundary = end
        while current < boundary {
            days.append(current)
            guard let next = calendar.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        return days
    }

    private static func dayEnd(_ day: Date, _ calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))
            ?? calendar.startOfDay(for: day)
    }
}

private extension Double {
    /// -1 / 0 / +1 sign, with exact zero mapping to 0 (no direction).
    var sign01: Int {
        if self > 0 { return 1 }
        if self < 0 { return -1 }
        return 0
    }
}
