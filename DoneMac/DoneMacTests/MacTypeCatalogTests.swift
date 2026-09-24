//
//  MacTypeCatalogTests.swift
//  DoneMacTests
//
//  A2: the Mac-specific risks in the type-catalog editor — the AppKit
//  Color↔hex conversion (the plan's B-3 sRGB-hop shim: `NSColor.getRed`
//  TRAPS on dynamic/catalog colors without hopping through sRGB first) and
//  the exact store operations the editor drives, on an ISOLATED catalog so
//  they don't touch the dogfood types. (The store's CRUD semantics
//  themselves are pinned by the shared EventTypeTemplateStoreTests.)
//

import XCTest
import SwiftUI
import Combine
@testable import Done

@MainActor
final class MacTypeCatalogTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private let dayStart = Date(timeIntervalSince1970: 1_773_100_800)  // 2026-03-10 UTC

    /// review #1: a type recolor/rename must rebuild the canvas frame — the
    /// surface subscribes to the catalog-change signal and drops its
    /// color-baked cache. Driven via an injected publisher (no shared-catalog
    /// pollution).
    func testCatalogChangeRebuildsSurfaceFrame() async throws {
        let bill = MacWorkBill()
        let persistence = try MacPersistence(location: .ephemeral(id: UUID()))
        let store = MacEventStore(persistence: persistence, bill: bill, calendar: calendar)
        await store.load()
        let start = dayStart.addingTimeInterval(9 * 3600)
        store.addCalendarEvent(Event(id: UUID(), title: "E",
                                     timeRanges: [.init(start: start, end: start.addingTimeInterval(3600))],
                                     kind: .event), now: dayStart)
        let clock = ClockHub(calendar: calendar, bill: bill, drivesTimer: false)
        let changes = PassthroughSubject<Void, Never>()
        let surface = CalendarSurfaceModel(
            store: store, clock: clock, calendar: calendar, bill: bill,
            anchor: dayStart, rangeMode: .week,
            catalogChanges: changes.eraseToAnyPublisher()
        )
        surface.activate(now: dayStart)
        let before = bill.count(.surfaceRebuilds)
        changes.send()   // a type recolor fires this
        XCTAssertGreaterThan(bill.count(.surfaceRebuilds), before,
                             "a catalog change rebuilds the visible frame (else recolors never reach the canvas)")
        surface.deactivate()
    }

    /// review #3: rename-collision / empty / no-op are rejected (nil); a valid
    /// rename returns the new title.
    func testResolvedRenameRejectsCollisionEmptyAndNoop() {
        let a = EventTypeTemplate(title: "Work", colorHex: "#0A84FF")
        let b = EventTypeTemplate(title: "Study", colorHex: "#34C759")
        let templates = [a, b]
        XCTAssertNil(TypeCatalogEditorView.resolvedRename(templates: templates, currentID: a.id, draft: "Study"),
                     "renaming onto an existing type is rejected (no silent merge)")
        XCTAssertNil(TypeCatalogEditorView.resolvedRename(templates: templates, currentID: a.id, draft: "   "),
                     "empty is rejected")
        XCTAssertNil(TypeCatalogEditorView.resolvedRename(templates: templates, currentID: a.id, draft: "Work"),
                     "no-op is rejected")
        XCTAssertEqual(TypeCatalogEditorView.resolvedRename(templates: templates, currentID: a.id, draft: "Deep Work"),
                       "Deep Work", "a genuinely new title applies")
    }

    func testColorHexRoundTripsConcreteColors() {
        for color in [Color.red, .green, .blue, Color(red: 0.2, green: 0.45, blue: 0.7)] {
            let hex = ColorHex.fromColor(color)
            XCTAssertTrue(hex.hasPrefix("#") && hex.count >= 7, "got \(hex)")
            _ = ColorHex.toColor(hex)   // must not trap
        }
    }

    /// The dynamic-color trap the sRGB hop exists to prevent: on AppKit,
    /// `NSColor(Color.accentColor).getRed(...)` traps unless converted to
    /// sRGB first. `fromColor` must return a usable hex, not crash.
    func testDynamicColorConvertsViaSRGBHop() {
        let hex = ColorHex.fromColor(.accentColor)
        XCTAssertTrue(hex.hasPrefix("#"), "a dynamic color still converts via the sRGB hop, got \(hex)")
    }

    /// The editor's operations (add / rename+recolor / delete) against an
    /// isolated catalog — the exact calls TypeCatalogEditorView makes.
    func testEditorStoreOperationsOnIsolatedCatalog() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EventTypes-\(UUID().uuidString)")
        let store = EventTypeTemplateStore(catalog: EventTypeCatalog(directory: dir, legacyDefaults: nil))

        store.add("Focus", colorHex: "#FF0000")
        XCTAssertTrue(store.templates.contains { $0.title == "Focus" && $0.colorHex == "#FF0000" })

        store.update(from: "Focus", to: "Deep Work", colorHex: "#00FF00")
        XCTAssertTrue(store.templates.contains { $0.title == "Deep Work" && $0.colorHex == "#00FF00" })
        XCTAssertFalse(store.templates.contains { $0.title == "Focus" }, "the old title is gone")

        store.remove(title: "Deep Work")
        XCTAssertFalse(store.templates.contains { $0.title == "Deep Work" })
    }
}
