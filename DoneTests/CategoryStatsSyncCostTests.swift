import XCTest
@testable import Done

/// What the category-stats payload adds to every widget sync, measured on a
/// heavy calendar: 68 days of history and plans, 15 events a day, two of them
/// embedded interrupts, and 20 recurring series (three crossing midnight).
/// The clock is the last day of a 31-day month, where the payload reaches
/// furthest back.
///
/// A measurement, not a gate: timings are printed (and attached) for the
/// record, and the only assertions are that the work measured is the work
/// meant. Timing assertions in this suite go red under CPU contention.
@MainActor
final class CategoryStatsSyncCostTests: XCTestCase {
    private let calendar = Calendar.current

    private func heavyEvents(now: Date) -> [Event] {
        var events: [Event] = []
        let today = calendar.startOfDay(for: now)
        let first = calendar.date(byAdding: .day, value: -60, to: today)!
        let types = ["Deep Work", "Meetings", "Exercise", "Reading", "Chores", "Commute", "Study", "Social", ""]
        for dayIndex in 0..<68 {
            let day = calendar.date(byAdding: .day, value: dayIndex, to: first)!
            for slot in 0..<13 {
                let start = day.addingTimeInterval(TimeInterval(7 * 3600 + slot * 55 * 60))
                let length = TimeInterval((40 + (slot * 7 + dayIndex) % 50) * 60)
                events.append(Event(title: "E\(dayIndex)-\(slot)", timeRanges: [.init(start: start, end: start + length)],
                                    type: types[(slot + dayIndex) % types.count]))
            }
            for child in 0..<2 {
                let parent = events[events.count - 1 - child * 3]
                let start = parent.timeRanges[0].start.addingTimeInterval(600)
                events.append(Event(title: "I\(dayIndex)-\(child)", timeRanges: [.init(start: start, end: start + 900)],
                                    type: "Break",
                                    interruptRelation: EventInterruptRelation(parentEventID: parent.id, occurrenceDate: start)))
            }
        }
        for series in 0..<20 {
            let anchor = calendar.date(byAdding: .day, value: -90 + series, to: today)!
            let crossesMidnight = series < 3
            let start = anchor.addingTimeInterval(crossesMidnight ? 23 * 3600 : TimeInterval((6 + series) * 3600))
            events.append(Event(title: "S\(series)", timeRanges: [.init(start: start, end: start + (crossesMidnight ? 7200 : 2700))],
                                repeatUnit: series % 2 == 0 ? .day : .week, type: types[series % types.count]))
        }
        return events
    }

    private func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    func testAddedCostPerSyncOnAHeavyCalendar() throws {
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 18))!
        let suite = "CategoryStatsSyncCost-\(UUID().uuidString)"
        let store = EventStore(defaults: UserDefaults(suiteName: suite)!, storage: .ephemeral(id: UUID()),
                               seedsSampleDataIfEmpty: false)
        store.widgetSyncClock = { now }
        store.reloadWidgetTimelines = {}
        store.rawCalendarEvents = heavyEvents(now: now)
        let events = store.canvasRenderableCalendarEvents
        XCTAssertEqual(events.count, 68 * 15 + 20)

        func millis(_ body: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }

        // The pieces. `build` is what now runs off the main actor on the
        // debounced path (and on it only for a flush that finds no reusable
        // build); the rest is what the main actor adds per sync.
        var payload: CategoryStatsPayload?
        var build: [Double] = [], handoff: [Double] = [], colourAndHash: [Double] = [], encode: [Double] = [],
            snapshots: [Double] = []
        var bytes = 0
        let window = WidgetSnapshotBuilder.window(now: now, calendar: calendar)
        for _ in 0..<9 {
            var handed: [Event] = []
            handoff.append(millis { handed = CategoryStatsBuilder.handoff(events) })
            build.append(millis {
                payload = CategoryStatsBuilder.payload(events: handed, now: now, calendar: calendar, colorHex: { _ in nil })
            })
            let built = try XCTUnwrap(payload)
            colourAndHash.append(millis {
                var coloured = built
                coloured.categories = coloured.categories?.map { category in
                    var c = category
                    c.colorHex = category.name.map { EventTypeTemplateStore.colorHex(for: $0) }
                    return c
                }
                var hasher = Hasher()
                hasher.combine(coloured.withoutWriteStamp)
                _ = hasher.finalize()
            })
            encode.append(millis { bytes = (try? JSONEncoder().encode(built))?.count ?? 0 })
            snapshots.append(millis {
                _ = WidgetSnapshotBuilder.snapshots(events: events, windowStart: window.start, windowEnd: window.end,
                                                   calendar: calendar,
                                                   colorHex: { EventTypeTemplateStore.colorHex(for: $0) })
            })
        }

        // End to end on the main actor: the first flush builds synchronously
        // (the rare path), every later one reuses the build. The steady-state
        // added cost is a reused flush minus the projection it always did.
        let coldFlush = millis { store.flushWidgetSnapshotSync() }
        let warmFlushes = (0..<9).map { _ in millis { store.flushWidgetSnapshotSync() } }

        let built = try XCTUnwrap(payload)
        let days = built.days?.count ?? 0
        let slices = built.days?.reduce(0) { $0 + ($1.slices?.count ?? 0) } ?? 0
        XCTAssertEqual(days, 37, "1 October to 6 November")
        XCTAssertGreaterThan(slices, 500)
        XCTAssertEqual(SharedWidgetData.readCategoryStats()?.days?.count, days, "the flush wrote this payload")

        let report = String(
            format: "category-stats sync cost (ms, median/max of %d) — off-main build %.2f/%.2f; "
                + "main actor: handoff %.3f/%.3f, colour+hash %.3f/%.3f, encode-on-write %.2f/%.2f; "
                + "flush cold %.2f, flush warm %.2f/%.2f vs existing projection %.2f/%.2f; "
                + "payload %d days, %d slices, %d bytes",
            build.count, median(build), build.max()!, median(handoff), handoff.max()!,
            median(colourAndHash), colourAndHash.max()!, median(encode), encode.max()!,
            coldFlush, median(warmFlushes), warmFlushes.max()!, median(snapshots), snapshots.max()!,
            days, slices, bytes
        )
        print(report)
        let attachment = XCTAttachment(string: report)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// What a lifecycle flush costs the main actor on the same calendar, in
    /// the four states the app can meet one in: nothing built yet (a flush
    /// within the debounce of launch), the first flush of a new day (the
    /// build from yesterday is reusable for every day but the new one), a
    /// flush right after an edit, and a flush with nothing new. The new day
    /// is the 31st, where the payload reaches furthest back. Each is timed
    /// around `flushWidgetSnapshotSync()` alone; whatever it hands off is
    /// awaited outside the timing. Printed, not asserted.
    func testFlushCostOnTheMainActor() async throws {
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 18))!
        let suite = "CategoryStatsFlushCost-\(UUID().uuidString)"
        let store = EventStore(defaults: UserDefaults(suiteName: suite)!, storage: .ephemeral(id: UUID()),
                               seedsSampleDataIfEmpty: false)
        var clock = now
        store.widgetSyncClock = { clock }
        store.reloadWidgetTimelines = {}
        store.rawCalendarEvents = heavyEvents(now: now)

        func millis(_ body: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }

        var cold: [Double] = [], newDay: [Double] = [], afterEdit: [Double] = [], unchanged: [Double] = []
        for round in 0..<5 {
            // A different calendar revision each round, so nothing is reused
            // from the round before.
            let tomorrow = now.addingTimeInterval(86_400)
            store.rawCalendarEvents.append(Event(title: "R\(round)", timeRanges: [
                .init(start: tomorrow.addingTimeInterval(-7200), end: tomorrow.addingTimeInterval(-3600))], type: "Round"))
            clock = now
            cold.append(millis { store.flushWidgetSnapshotSync() })
            await store.awaitDeferredWidgetSync()
            unchanged.append(millis { store.flushWidgetSnapshotSync() })

            clock = now.addingTimeInterval(86_400)
            newDay.append(millis { store.flushWidgetSnapshotSync() })
            await store.awaitDeferredWidgetSync()

            var edited = store.rawCalendarEvents[store.rawCalendarEvents.count - 1]
            edited.title = "R\(round) edited"
            store.updateCalendarEvent(edited)
            afterEdit.append(millis { store.flushWidgetSnapshotSync() })
            await store.awaitDeferredWidgetSync()
        }
        let written = try XCTUnwrap(SharedWidgetData.readCategoryStats())
        XCTAssertEqual(written.coverageEnd, CategoryStatsBuilder.coverage(now: clock, calendar: calendar).end)
        let expected = CategoryStatsBuilder.payload(events: store.canvasRenderableCalendarEvents, now: clock,
                                                    calendar: calendar, colorHex: { _ in nil })
        XCTAssertEqual(CategoryStats.hours(in: written, period: .month, asOf: clock),
                       CategoryStats.hours(in: expected, period: .month, asOf: clock),
                       "the work timed is the work meant: the last build landed")
        XCTAssertGreaterThan(CategoryStats.hours(in: written, period: .today, asOf: clock)["Round"] ?? 0, 0)

        let report = String(
            format: "category-stats flush on the main actor (ms, median/max of %d) — "
                + "cold %.2f/%.2f, new day %.2f/%.2f, after an edit %.2f/%.2f, unchanged %.2f/%.2f; raw cold %@ "
                + "new day %@ after edit %@ unchanged %@",
            cold.count, median(cold), cold.max()!, median(newDay), newDay.max()!, median(afterEdit), afterEdit.max()!,
            median(unchanged), unchanged.max()!,
            cold.map { String(format: "%.2f", $0) }.joined(separator: ","),
            newDay.map { String(format: "%.2f", $0) }.joined(separator: ","),
            afterEdit.map { String(format: "%.2f", $0) }.joined(separator: ","),
            unchanged.map { String(format: "%.2f", $0) }.joined(separator: ",")
        )
        print(report)
        let attachment = XCTAttachment(string: report)
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
