#!/usr/bin/env swift
// Injects realistic mock data into the Done app's UserDefaults on the simulator.
// Run: swift inject-mock-data.swift

import Foundation

// ── The plist path (passed as arg or auto-detected) ──
let plistPath: String
if CommandLine.arguments.count > 1 {
    plistPath = CommandLine.arguments[1]
} else {
    fatalError("Usage: swift inject-mock-data.swift <path-to-plist>")
}

// ── Models (must match Done app's Codable format exactly) ──

struct TimeRange: Codable { var start: Date; var end: Date }
struct Event: Codable {
    var id: UUID
    var title: String
    var note: String
    var location: String
    var timeRanges: [TimeRange]
    var deadline: Date?
    var repeatUnit: String
    var isAllDay: Bool
    var isDone: Bool
    var repeatInterval: Int
    var repeatEndType: String
    var repeatEndDate: Date?
    var repeatEndCount: Int?
    var priority: Int
    var status: String
    var createdAt: Date
    var completeAt: Date?
    var tags: [String]
    var type: String
    var additionalTypes: [String]?
    var typeWeights: [String: Double]?
    var colorDepth: Double
    var recurrenceParentId: UUID?
    var recurrenceInstanceDate: Date?
    var recurrenceExceptionDates: [Date]
    var timerStartedAt: Date?
    var linkedCalendarEventId: UUID?
    var linkedTodoEventId: UUID?
    var listID: UUID?
    var suggestedLogTemplateID: String?
    var suggestedLogTemplateConfidence: Double?
    var suggestedLogTemplateUpdatedAt: Date?
    var suggestedLogTemplateSource: String?
    var displayKind: String
}

struct OccurrenceKey: Codable, Hashable {
    var eventID: UUID
    var baseSeriesEventID: UUID?
    var occurrenceDate: Date
    var kind: String
}

struct LogRecord: Codable {
    var id: OccurrenceKey
    var eventID: UUID
    var baseSeriesEventID: UUID?
    var occurrenceDate: Date
    var suggestedTemplateID: String?
    var selectedTemplateID: String?
    var completionStatus: String?
    var actualDurationMinutes: Int?
    var summary: String
    var note: String
    var effort: Int?
    var emotions: [String]
    var behaviors: [String]
    var templateAnswers: [String: String]
    var timelineItems: [[String: String]]
    var createdAt: Date
    var updatedAt: Date
}

struct TodoList: Codable {
    var id: UUID
    var title: String
    var colorName: String
    var createdAt: Date
}

struct EventTypeTemplate: Codable {
    var id: UUID
    var title: String
    var colorHex: String
}

// ── Helpers ──
let cal = Calendar.current
func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
    cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

func makeEvent(
    title: String, type: String, start: Date, end: Date,
    note: String = "", isDone: Bool = false, status: String = "active"
) -> Event {
    Event(
        id: UUID(), title: title, note: note, location: "",
        timeRanges: [TimeRange(start: start, end: end)],
        deadline: nil, repeatUnit: "none", isAllDay: false, isDone: isDone,
        repeatInterval: 1, repeatEndType: "none", repeatEndDate: nil, repeatEndCount: nil,
        priority: 0, status: status, createdAt: start, completeAt: isDone ? end : nil,
        tags: [], type: type, additionalTypes: nil, typeWeights: nil,
        colorDepth: 1.0, recurrenceParentId: nil, recurrenceInstanceDate: nil,
        recurrenceExceptionDates: [], timerStartedAt: nil,
        linkedCalendarEventId: nil, linkedTodoEventId: nil, listID: nil,
        suggestedLogTemplateID: nil, suggestedLogTemplateConfidence: nil,
        suggestedLogTemplateUpdatedAt: nil, suggestedLogTemplateSource: nil,
        displayKind: "regular"
    )
}

func makeLog(
    event: Event, on day: Date, status: String = "completed",
    duration: Int, summary: String, effort: Int,
    emotions: [String], behaviors: [String]
) -> LogRecord {
    let dayStart = cal.startOfDay(for: day)
    return LogRecord(
        id: OccurrenceKey(eventID: event.id, baseSeriesEventID: nil, occurrenceDate: dayStart, kind: "single"),
        eventID: event.id, baseSeriesEventID: nil, occurrenceDate: dayStart,
        suggestedTemplateID: nil, selectedTemplateID: nil,
        completionStatus: status, actualDurationMinutes: duration,
        summary: summary, note: "", effort: effort,
        emotions: emotions, behaviors: behaviors,
        templateAnswers: [:], timelineItems: [],
        createdAt: day, updatedAt: day
    )
}

// ── Generate 2 weeks of data: April 1-14, 2026 ──
var calendarEvents: [Event] = []
var logs: [LogRecord] = []

struct DayPlan {
    let items: [(title: String, type: String, hStart: Int, mStart: Int, hEnd: Int, mEnd: Int,
                  effort: Int, emotions: [String], behaviors: [String], summary: String)]
}

let plans: [DayPlan] = [
    // Productive weekday
    DayPlan(items: [
        ("Morning Run", "Exercise", 7, 0, 7, 45, 3, ["energized", "happy"], ["consistent", "as_planned"], "Solid run, nice weather"),
        ("Deep Work: SwiftUI Gestures", "Work", 9, 30, 12, 0, 4, ["focused", "calm"], ["deep_work"], "Refactored drag gesture system"),
        ("Lunch Break", "Personal", 12, 0, 13, 0, 1, ["calm"], ["as_planned"], "Quick lunch and walk"),
        ("Code Review", "Work", 14, 0, 15, 30, 3, ["focused"], ["collaborative"], "Reviewed 2 PRs"),
        ("Read DDIA Ch.6", "Study", 21, 0, 22, 0, 4, ["focused", "tired"], ["deep_work"], "Partitioning chapter - dense but clear"),
    ]),
    // Gym + meetings day
    DayPlan(items: [
        ("Gym - Upper Body", "Exercise", 7, 30, 8, 45, 4, ["energized"], ["consistent"], "Bench press PR: 80kg x 5"),
        ("Sprint Planning", "Work", 10, 0, 11, 0, 2, ["neutral"], ["collaborative"], "Planned next 2 weeks"),
        ("Feature: MCP Integration", "Work", 11, 30, 13, 30, 5, ["focused", "energized"], ["deep_work", "proactive"], "Got Supabase sync working"),
        ("API Debugging", "Work", 14, 30, 17, 0, 5, ["frustrated", "focused"], ["deep_work", "rushed"], "Edge case in auth flow - finally fixed"),
        ("Piano Practice", "Creative", 20, 0, 20, 45, 3, ["calm", "happy"], ["consistent"], "Chopin Nocturne Op.9 No.2 getting smoother"),
    ]),
    // Stressed day
    DayPlan(items: [
        ("Skipped workout", "Personal", 8, 0, 8, 30, 1, ["tired"], ["avoidant"], "Too tired, stayed in bed"),
        ("Production Bug Triage", "Work", 9, 30, 12, 0, 5, ["stressed", "anxious"], ["rushed", "interrupted"], "Users reporting data loss - critical"),
        ("Hotfix + Deploy", "Work", 13, 0, 16, 30, 5, ["stressed", "focused"], ["deep_work", "rushed"], "Root cause found: race condition in sync"),
        ("Regression Tests", "Work", 17, 0, 18, 30, 4, ["focused", "tired"], ["deep_work"], "Added 12 test cases for the fix"),
        ("Netflix", "Personal", 21, 0, 22, 30, 1, ["tired", "calm"], ["distracted"], "Needed to decompress"),
    ]),
    // Weekend relaxed
    DayPlan(items: [
        ("Long Run - River Trail", "Exercise", 8, 30, 10, 0, 4, ["energized", "happy", "calm"], ["consistent", "as_planned"], "10K run, gorgeous morning"),
        ("Brunch with Alex & Sam", "Social", 11, 0, 13, 0, 1, ["happy", "energized"], ["collaborative"], "Great catch-up, talked about hiking trip"),
        ("Side Project: Done MCP", "Work", 15, 0, 17, 30, 3, ["focused", "happy"], ["deep_work", "proactive"], "Built query tools for life data"),
        ("Piano Practice", "Creative", 19, 30, 20, 30, 3, ["calm", "focused"], ["consistent"], "Nailed the middle section finally"),
    ]),
    // Weekend social
    DayPlan(items: [
        ("Morning Yoga", "Exercise", 9, 0, 10, 0, 2, ["calm", "happy"], ["as_planned"], "Gentle flow, good for recovery"),
        ("Hiking with friends", "Social", 11, 0, 15, 30, 3, ["happy", "energized"], ["as_planned"], "8km trail, beautiful views"),
        ("Cooking: Thai Green Curry", "Personal", 17, 30, 19, 0, 2, ["calm", "happy"], ["proactive"], "New recipe - turned out great"),
        ("Reading: Sapiens", "Study", 21, 0, 22, 30, 3, ["focused", "calm"], ["deep_work"], "Agricultural revolution chapter"),
    ]),
    // Light recovery day
    DayPlan(items: [
        ("Easy Recovery Run", "Exercise", 7, 0, 7, 30, 2, ["calm"], ["consistent"], "Easy pace, just moving"),
        ("Refactoring: Event Model", "Work", 10, 0, 12, 0, 3, ["focused", "calm"], ["deep_work", "proactive"], "Cleaned up type system"),
        ("Online Course: SwiftUI", "Study", 14, 0, 15, 30, 3, ["focused", "energized"], ["deep_work"], "Advanced animations module"),
        ("Coffee with mentor", "Social", 16, 0, 17, 0, 1, ["happy", "calm"], ["collaborative"], "Got great career advice"),
    ]),
]

// Map days to plans (cycling through with variation)
let planOrder = [0, 1, 0, 2, 5, 3, 4, 0, 1, 2, 0, 1, 5, 3]

for dayOffset in 0..<14 {
    let dayDate = date(2026, 4, 1 + dayOffset)
    let plan = plans[planOrder[dayOffset]]

    for item in plan.items {
        let start = date(2026, 4, 1 + dayOffset, item.hStart, item.mStart)
        let end = date(2026, 4, 1 + dayOffset, item.hEnd, item.mEnd)
        let event = makeEvent(
            title: item.title, type: item.type,
            start: start, end: end,
            isDone: true, status: "completed"
        )
        calendarEvents.append(event)

        let duration = (item.hEnd * 60 + item.mEnd) - (item.hStart * 60 + item.mStart)
        let log = makeLog(
            event: event, on: dayDate,
            duration: duration, summary: item.summary,
            effort: item.effort, emotions: item.emotions, behaviors: item.behaviors
        )
        logs.append(log)
    }
}

// Add a few upcoming (not-done) events for today and tomorrow
let upcoming = [
    makeEvent(title: "Morning Run", type: "Exercise",
              start: date(2026, 4, 15, 7, 0), end: date(2026, 4, 15, 7, 45)),
    makeEvent(title: "Team Standup", type: "Work",
              start: date(2026, 4, 15, 10, 0), end: date(2026, 4, 15, 10, 15)),
    makeEvent(title: "MCP Server Polish", type: "Work",
              start: date(2026, 4, 15, 10, 30), end: date(2026, 4, 15, 13, 0)),
    makeEvent(title: "Gym - Legs Day", type: "Exercise",
              start: date(2026, 4, 16, 7, 30), end: date(2026, 4, 16, 8, 45)),
    makeEvent(title: "Design Review", type: "Work",
              start: date(2026, 4, 16, 14, 0), end: date(2026, 4, 16, 15, 0)),
]
calendarEvents.append(contentsOf: upcoming)

// Todo events
let defaultListId = UUID()
let todoEvents: [Event] = [
    "Order running shoes",
    "Reply to Alex's email",
    "Backup photos",
    "Book dentist appointment",
    "Update portfolio website",
].enumerated().map { i, title in
    var e = makeEvent(title: title, type: "", start: Date(), end: Date(),
                      isDone: i < 2, status: i < 2 ? "completed" : "active")
    e.timeRanges = []
    e.listID = defaultListId
    return e
}

let todoLists = [
    TodoList(id: defaultListId, title: "Inbox", colorName: "blue", createdAt: date(2026, 3, 1)),
    TodoList(id: UUID(), title: "Projects", colorName: "purple", createdAt: date(2026, 3, 1)),
]

let eventTypes = [
    EventTypeTemplate(id: UUID(), title: "Exercise", colorHex: "#FF6B35"),
    EventTypeTemplate(id: UUID(), title: "Study", colorHex: "#4ECDC4"),
    EventTypeTemplate(id: UUID(), title: "Work", colorHex: "#0A84FF"),
    EventTypeTemplate(id: UUID(), title: "Sleep", colorHex: "#AF52DE"),
    EventTypeTemplate(id: UUID(), title: "Social", colorHex: "#FF3B30"),
    EventTypeTemplate(id: UUID(), title: "Personal", colorHex: "#FF9500"),
    EventTypeTemplate(id: UUID(), title: "Creative", colorHex: "#30D158"),
]

// ── Encode and write to plist ──
let encoder = JSONEncoder()
// Must match the app's default: .deferredToDate (timeIntervalSinceReferenceDate)

let calendarData = try encoder.encode(calendarEvents)
let todoData = try encoder.encode(todoEvents)
let logData = try encoder.encode(logs)
let todoListData = try encoder.encode(todoLists)
let eventTypeData = try encoder.encode(eventTypes)

// Read existing plist or create new
var plist: [String: Any]
if let data = FileManager.default.contents(atPath: plistPath),
   let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
    plist = dict
} else {
    plist = [:]
}

// The four event-data arrays moved OUT of UserDefaults into
// `Library/Application Support/EventStore/<slot>.json` (see
// `DurableEventStorage` — cfprefsd does not durably hold a write, which is
// what the swipe-to-kill data loss turned out to be). Writing them into the
// plist here would keep "succeeding" while the app ignored every byte, so
// they are written in the real on-disk format instead, and the stale plist
// keys are actively removed so nothing can read them by accident.
//
// File format: one line of header JSON, a newline, then the rows JSON.
struct SlotHeader: Codable {
    var schema = 1
    var seq: UInt64 = 1
    var writtenAt = Date()
    var wiped = false
    var count: Int
}

// <container>/Library/Preferences/<bid>.plist -> <container>/Library/Application Support/EventStore
let preferencesDir = URL(fileURLWithPath: plistPath).deletingLastPathComponent()
guard preferencesDir.lastPathComponent == "Preferences" else {
    fatalError("expected a .../Library/Preferences/<bundleid>.plist path, got \(plistPath) — "
               + "cannot derive the EventStore directory, refusing to write a fixture the app will ignore")
}
let storeDir = preferencesDir
    .deletingLastPathComponent()
    .appendingPathComponent("Application Support", isDirectory: true)
    .appendingPathComponent("EventStore", isDirectory: true)
try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)

func writeSlot(_ name: String, rows: Data, count: Int) throws {
    var payload = try JSONEncoder().encode(SlotHeader(count: count))
    payload.append(0x0A)
    payload.append(rows)
    try payload.write(to: storeDir.appendingPathComponent("\(name).json"), options: .atomic)
    // A stale `.bak` from a previous fixture would be promoted if the primary
    // were ever unreadable, quietly resurrecting the old dataset.
    try? FileManager.default.removeItem(at: storeDir.appendingPathComponent("\(name).bak"))
}

try writeSlot("calendarEvents", rows: calendarData, count: calendarEvents.count)
try writeSlot("events", rows: todoData, count: todoEvents.count)
try writeSlot("calendarEventLogRecords", rows: logData, count: logs.count)
try writeSlot("todoLists", rows: todoListData, count: todoLists.count)
// A manifest that records these as committed, so a later missing file is
// reported as a fault instead of being mistaken for a first launch.
let manifest: [String: Any] = [
    "schema": 1,
    "legacyPurged": false,
    "slots": ["calendarEvents", "events", "calendarEventLogRecords", "todoLists"]
        .reduce(into: [String: Any]()) { $0[$1] = ["everCommitted": true, "seq": 1] },
]
try JSONSerialization.data(withJSONObject: manifest)
    .write(to: storeDir.appendingPathComponent("manifest.json"), options: .atomic)

for stale in ["calendarEvents", "events", "calendarEventLogRecords", "todoLists"] {
    plist.removeValue(forKey: stale)
}
// Event types moved to `Application Support/EventTypes/templates.json`. The
// plist key is now a MIGRATION SOURCE, consulted once and only when no file
// exists — so writing the fixture there would be silently ignored on any
// simulator that has already launched the app. Drop it for the same reason
// the slots above are dropped.
plist.removeValue(forKey: "eventTypeTemplates")

let typesDir = preferencesDir
    .deletingLastPathComponent()
    .appendingPathComponent("Application Support", isDirectory: true)
    .appendingPathComponent("EventTypes", isDirectory: true)
try FileManager.default.createDirectory(at: typesDir, withIntermediateDirectories: true)
try eventTypeData.write(to: typesDir.appendingPathComponent("templates.json"), options: .atomic)
try? FileManager.default.removeItem(at: typesDir.appendingPathComponent("templates.bak"))

let output = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
try output.write(to: URL(fileURLWithPath: plistPath))

print("Injected into \(storeDir.path) (+ templates.json into \(typesDir.path)):")
print("  \(calendarEvents.count) calendar events")
print("  \(todoEvents.count) todos")
print("  \(logs.count) logs")
print("  \(todoLists.count) todo lists")
print("  \(eventTypes.count) event types")
print("Done!")
