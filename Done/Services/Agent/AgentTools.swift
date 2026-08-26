//
//  AgentTools.swift
//  Done
//

import Foundation

// MARK: - Tool Definitions

enum AgentTool: String, CaseIterable {
    case createTodo
    case createCalendarEvent
    case listTodos
    case listCalendarEvents
    case updateTodo
    case completeTodo
    case deleteTodo
    case deleteCalendarEvent
    case getScheduleForDate
    case getUserData

    var definition: LLMToolDefinition {
        switch self {
        case .createTodo:
            return LLMToolDefinition(
                name: "createTodo",
                description: "Create a new todo item.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "Todo title"],
                        "note": ["type": "string", "description": "Optional note/description"],
                        "priority": ["type": "integer", "description": "Priority: 0=None, 1=Low, 2=Medium, 3=High", "enum": [0, 1, 2, 3]],
                        "tags": ["type": "array", "items": ["type": "string"], "description": "Optional tags"],
                        "type": ["type": "string", "description": "Event type/category. MUST be one of the available types listed in the system prompt. Do NOT create new types."],
                        "deadline": ["type": "string", "description": "Optional deadline as yyyy-MM-dd'T'HH:mm:ss (or yyyy-MM-dd)"],
                    ] as [String: Any],
                    "required": ["title"],
                ] as [String: Any]
            )

        case .createCalendarEvent:
            return LLMToolDefinition(
                name: "createCalendarEvent",
                description: "Create a calendar event with a specific start and end time.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "title": ["type": "string", "description": "Event title"],
                        "startTime": ["type": "string", "description": "Start time in ISO8601 format (yyyy-MM-dd'T'HH:mm:ss)"],
                        "endTime": ["type": "string", "description": "End time in ISO8601 format (yyyy-MM-dd'T'HH:mm:ss)"],
                        "note": ["type": "string", "description": "Optional note"],
                        "type": ["type": "string", "description": "Event type/category. MUST be one of the available types listed in the system prompt. Do NOT create new types."],
                        "tags": ["type": "array", "items": ["type": "string"], "description": "Optional tags"],
                    ] as [String: Any],
                    "required": ["title", "startTime", "endTime"],
                ] as [String: Any]
            )

        case .listTodos:
            return LLMToolDefinition(
                name: "listTodos",
                description: "List todo items. Can filter by status.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "status": ["type": "string", "description": "Filter by status: active, completed, or all", "enum": ["active", "completed", "all"]],
                    ] as [String: Any],
                    "required": [] as [String],
                ] as [String: Any]
            )

        case .listCalendarEvents:
            return LLMToolDefinition(
                name: "listCalendarEvents",
                description: "List calendar events. Can filter by date range.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "startDate": ["type": "string", "description": "Filter start date in ISO8601 format"],
                        "endDate": ["type": "string", "description": "Filter end date in ISO8601 format"],
                    ] as [String: Any],
                    "required": [] as [String],
                ] as [String: Any]
            )

        case .updateTodo:
            return LLMToolDefinition(
                name: "updateTodo",
                description: "Update properties of an existing todo by its ID.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "UUID of the todo to update"],
                        "title": ["type": "string", "description": "New title"],
                        "note": ["type": "string", "description": "New note"],
                        "priority": ["type": "integer", "description": "New priority: 0-3"],
                        "tags": ["type": "array", "items": ["type": "string"], "description": "New tags"],
                        "type": ["type": "string", "description": "New event type/category. MUST be one of the available types listed in the system prompt. Do NOT create new types."],
                        "deadline": ["type": ["string", "null"], "description": "New deadline as yyyy-MM-dd'T'HH:mm:ss (or yyyy-MM-dd), or JSON null to remove the existing deadline"],
                    ] as [String: Any],
                    "required": ["id"],
                ] as [String: Any]
            )

        case .completeTodo:
            return LLMToolDefinition(
                name: "completeTodo",
                description: "Mark a todo as completed by its ID.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "UUID of the todo to complete"],
                    ] as [String: Any],
                    "required": ["id"],
                ] as [String: Any]
            )

        case .deleteTodo:
            return LLMToolDefinition(
                name: "deleteTodo",
                description: "Delete a todo by its ID.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "UUID of the todo to delete"],
                    ] as [String: Any],
                    "required": ["id"],
                ] as [String: Any]
            )

        case .deleteCalendarEvent:
            return LLMToolDefinition(
                name: "deleteCalendarEvent",
                description: "Delete a calendar event by its ID.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "id": ["type": "string", "description": "UUID of the calendar event to delete"],
                    ] as [String: Any],
                    "required": ["id"],
                ] as [String: Any]
            )

        case .getScheduleForDate:
            return LLMToolDefinition(
                name: "getScheduleForDate",
                description: "Get the complete schedule (todos + calendar events) for a specific date.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "date": ["type": "string", "description": "Date in ISO8601 format (yyyy-MM-dd)"],
                    ] as [String: Any],
                    "required": ["date"],
                ] as [String: Any]
            )

        case .getUserData:
            return LLMToolDefinition(
                name: "getUserData",
                description: "Get all user data (todos and calendar events) for behavioral analysis. Returns raw data including timestamps, types, tags, completion status, and durations. Use this when the user asks about their habits, patterns, productivity, or personality.",
                parameters: [
                    "type": "object",
                    "properties": [
                        "days": ["type": "integer", "description": "Number of days to look back (default 30)"],
                    ] as [String: Any],
                    "required": [] as [String],
                ] as [String: Any]
            )
        }
    }

    /// Containment for gh#135: a destructive tool is never offered to the
    /// model AND is refused at dispatch even when called by name. Both gates
    /// consult this one predicate — never a second hand-maintained list.
    /// The cases stay in the enum: display strings reference them, and the
    /// durable in-app confirm flow (a later slice) will reuse them.
    var isDestructive: Bool {
        switch self {
        case .deleteTodo, .deleteCalendarEvent:
            return true
        case .createTodo, .createCalendarEvent, .listTodos, .listCalendarEvents,
             .updateTodo, .completeTodo, .getScheduleForDate, .getUserData:
            return false
        }
    }

    /// Everything the model is allowed to call — destructive tools excluded.
    static var allDefinitions: [LLMToolDefinition] {
        allCases.filter { !$0.isDestructive }.map(\.definition)
    }
}

// MARK: - Tool Runner

enum AgentToolRunner {
    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let dateOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let displayDateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static func execute(toolName: String, arguments: String, store: EventStore) -> String {
        guard let data = arguments.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return jsonResult(success: false, message: "Invalid arguments JSON")
        }

        guard let tool = AgentTool(rawValue: toolName) else {
            return jsonResult(success: false, message: "Unknown tool: \(toolName)")
        }

        // gh#135 containment: refuse destructive tools before any store
        // lookup or mutation. The model is never offered these tools, but a
        // hallucinated call by name must dead-end here, not in the executor.
        if tool.isDestructive {
            return jsonResult(
                success: false,
                message: "Deletion requires in-app confirmation and is not available to the assistant. The user can delete the item manually in the app."
            )
        }

        switch tool {
        case .createTodo:
            return executeCreateTodo(args: args, store: store)
        case .createCalendarEvent:
            return executeCreateCalendarEvent(args: args, store: store)
        case .listTodos:
            return executeListTodos(args: args, store: store)
        case .listCalendarEvents:
            return executeListCalendarEvents(args: args, store: store)
        case .updateTodo:
            return executeUpdateTodo(args: args, store: store)
        case .completeTodo:
            return executeCompleteTodo(args: args, store: store)
        case .deleteTodo:
            return executeDeleteTodo(args: args, store: store)
        case .deleteCalendarEvent:
            return executeDeleteCalendarEvent(args: args, store: store)
        case .getScheduleForDate:
            return executeGetScheduleForDate(args: args, store: store)
        case .getUserData:
            return executeGetUserData(args: args, store: store)
        }
    }

    // MARK: - Tool Implementations

    private static func executeCreateTodo(args: [String: Any], store: EventStore) -> String {
        guard let title = args["title"] as? String, !title.isEmpty else {
            return jsonResult(success: false, message: "Title is required")
        }

        // Invariant: an unparseable deadline rejects the whole create — no
        // todo is added — rather than silently creating one without the
        // deadline the model asked for. Validated before construction, same
        // idiom as executeCreateCalendarEvent.
        let deadlineArg = dateArgument(args, key: "deadline")
        if case .invalid = deadlineArg {
            return jsonResult(success: false, message: "Invalid deadline format. Use yyyy-MM-dd'T'HH:mm:ss or yyyy-MM-dd. The todo was not created.")
        }

        var event = Event(title: title)
        event.note = args["note"] as? String ?? ""
        event.priority = args["priority"] as? Int ?? 0
        event.tags = args["tags"] as? [String] ?? []
        event.type = args["type"] as? String ?? ""
        if case .set(let deadline) = deadlineArg {
            event.deadline = deadline
        }
        // .remove (explicit JSON null) and .absent both mean: created
        // without a deadline — a new todo has none to remove.

        store.addWithAutoPlacement(event)
        return jsonResult(success: true, message: "Created todo '\(title)'", data: ["id": event.id.uuidString])
    }

    private static func executeCreateCalendarEvent(args: [String: Any], store: EventStore) -> String {
        guard let title = args["title"] as? String,
              let startStr = args["startTime"] as? String,
              let endStr = args["endTime"] as? String else {
            return jsonResult(success: false, message: "title, startTime, endTime are required")
        }

        guard let startTime = parseDate(startStr),
              let endTime = parseDate(endStr) else {
            return jsonResult(success: false, message: "Invalid date format. Use yyyy-MM-dd'T'HH:mm:ss")
        }

        var event = Event(
            title: title,
            timeRanges: [Event.TimeRange(start: startTime, end: endTime)]
        )
        event.note = args["note"] as? String ?? ""
        event.type = args["type"] as? String ?? ""
        event.tags = args["tags"] as? [String] ?? []
        event = EventLogTemplateAdvisor().applySuggestion(to: event)
        store.addCalendarEvent(event)
        return jsonResult(success: true, message: "Created calendar event '\(title)' from \(displayDateTime.string(from: startTime)) to \(displayDateTime.string(from: endTime))", data: ["id": event.id.uuidString])
    }

    private static func executeListTodos(args: [String: Any], store: EventStore) -> String {
        let statusFilter = args["status"] as? String ?? "active"
        let events: [Event]
        switch statusFilter {
        case "completed":
            events = store.completedEvents
        case "all":
            events = store.events
        default:
            events = store.activeEvents
        }

        let items: [[String: Any]] = events.map { event in
            var item: [String: Any] = [
                "id": event.id.uuidString,
                "title": event.title,
                "status": event.status.rawValue,
                "priority": event.priority,
            ]
            if !event.note.isEmpty { item["note"] = event.note }
            if !event.tags.isEmpty { item["tags"] = event.tags }
            if !event.type.isEmpty { item["type"] = event.type }
            if let deadline = event.deadline { item["deadline"] = displayDateTime.string(from: deadline) }
            return item
        }

        let resultData = try? JSONSerialization.data(withJSONObject: ["todos": items, "count": items.count])
        return String(data: resultData ?? Data(), encoding: .utf8) ?? "[]"
    }

    private static func executeListCalendarEvents(args: [String: Any], store: EventStore) -> String {
        // Deliberately `rawCalendarEvents` (NOT the canvasRenderable
        // filter): the agent tool semantic is "list everything that
        // belongs to the user's calendar", which logically includes
        // absorbed-into-parent todos.  Filtering would hide the
        // relationship from the agent and break questions like
        // "did I include reviewing the slides under the meeting?".
        // Future polish (deferred): surface `absorbedIntoEventID` as
        // an exposed field so the agent can reason about parent ↔
        // child relationships, then the consumer (LLM) can decide
        // whether to deduplicate.
        var events = store.rawCalendarEvents

        if let startStr = args["startDate"] as? String, let startDate = parseDate(startStr) {
            events = events.filter { event in
                guard let range = event.primaryTimeRange else { return false }
                return range.end >= startDate
            }
        }
        if let endStr = args["endDate"] as? String, let endDate = parseDate(endStr) {
            events = events.filter { event in
                guard let range = event.primaryTimeRange else { return false }
                return range.start <= endDate
            }
        }

        let items: [[String: Any]] = events.map { event in
            var item: [String: Any] = [
                "id": event.id.uuidString,
                "title": event.title,
            ]
            if let range = event.primaryTimeRange {
                item["startTime"] = displayDateTime.string(from: range.start)
                item["endTime"] = displayDateTime.string(from: range.end)
            }
            if !event.type.isEmpty { item["type"] = event.type }
            if !event.note.isEmpty { item["note"] = event.note }
            // Surface absorption so the LLM can deduplicate / reason
            // about parent ↔ child rather than treating each absorbed
            // todo as an independent calendar entry.
            if let parent = event.absorbedIntoEventID {
                item["absorbedIntoEventID"] = parent.uuidString
            }
            return item
        }

        // `count` reports the canvas-visible count (excluding absorbed
        // todos) so it agrees with `AgentService.systemPrompt`'s count
        // and with the user's perception of "how many events". The
        // detailed `events` array still includes absorbed items with
        // their relationship field for the LLM's own analysis.
        let canvasCount = events.filter { $0.absorbedIntoEventID == nil }.count
        let resultData = try? JSONSerialization.data(withJSONObject: ["events": items, "count": canvasCount, "rawCount": items.count])
        return String(data: resultData ?? Data(), encoding: .utf8) ?? "[]"
    }

    private static func executeUpdateTodo(args: [String: Any], store: EventStore) -> String {
        guard let idStr = args["id"] as? String, let id = UUID(uuidString: idStr) else {
            return jsonResult(success: false, message: "Valid UUID id is required")
        }

        guard var event = store.events.first(where: { $0.id == id }) else {
            return jsonResult(success: false, message: "Todo not found with id: \(idStr)")
        }

        // Invariant: deadline validation precedes ALL field application,
        // and rejection is whole-update — a rejected call leaves the todo
        // entirely untouched so the model can correct and resend the whole
        // call. (The other fields carry no parse step that could fail: a
        // mistyped value merely fails its `as?` cast and is skipped.)
        // Same idiom as executeCreateCalendarEvent (parse first, apply
        // after).
        let deadlineArg = dateArgument(args, key: "deadline")
        if case .invalid = deadlineArg {
            return jsonResult(success: false, message: "Invalid deadline format. Use yyyy-MM-dd'T'HH:mm:ss or yyyy-MM-dd to set a deadline, or JSON null to remove it. Nothing was updated.")
        }

        if let title = args["title"] as? String { event.title = title }
        if let note = args["note"] as? String { event.note = note }
        if let priority = args["priority"] as? Int { event.priority = priority }
        if let tags = args["tags"] as? [String] { event.tags = tags }
        if let type = args["type"] as? String { event.type = type }

        var removedDeadline = false
        switch deadlineArg {
        case .absent, .invalid:
            break // .absent leaves the deadline untouched; .invalid was rejected above
        case .remove:
            event.deadline = nil
            removedDeadline = true
        case .set(let deadline):
            event.deadline = deadline
        }

        store.update(event)
        let message = removedDeadline
            ? "Updated todo '\(event.title)' and removed its deadline"
            : "Updated todo '\(event.title)'"
        return jsonResult(success: true, message: message)
    }

    private static func executeCompleteTodo(args: [String: Any], store: EventStore) -> String {
        guard let idStr = args["id"] as? String, let id = UUID(uuidString: idStr) else {
            return jsonResult(success: false, message: "Valid UUID id is required")
        }

        guard let event = store.events.first(where: { $0.id == id }) else {
            return jsonResult(success: false, message: "Todo not found with id: \(idStr)")
        }

        store.markComplete(event)
        return jsonResult(success: true, message: "Completed todo '\(event.title)'")
    }

    private static func executeDeleteTodo(args: [String: Any], store: EventStore) -> String {
        guard let idStr = args["id"] as? String, let id = UUID(uuidString: idStr) else {
            return jsonResult(success: false, message: "Valid UUID id is required")
        }

        guard let event = store.events.first(where: { $0.id == id }) else {
            return jsonResult(success: false, message: "Todo not found with id: \(idStr)")
        }

        store.delete(event)
        return jsonResult(success: true, message: "Deleted todo '\(event.title)'")
    }

    private static func executeDeleteCalendarEvent(args: [String: Any], store: EventStore) -> String {
        guard let idStr = args["id"] as? String, let id = UUID(uuidString: idStr) else {
            return jsonResult(success: false, message: "Valid UUID id is required")
        }

        guard let event = store.rawCalendarEvents.first(where: { $0.id == id }) else {
            return jsonResult(success: false, message: "Calendar event not found with id: \(idStr)")
        }

        store.deleteCalendarEvent(event)
        return jsonResult(success: true, message: "Deleted calendar event '\(event.title)'")
    }

    private static func executeGetScheduleForDate(args: [String: Any], store: EventStore) -> String {
        guard let dateStr = args["date"] as? String else {
            return jsonResult(success: false, message: "date is required")
        }

        guard let date = parseDate(dateStr) else {
            return jsonResult(success: false, message: "Invalid date format")
        }

        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!

        // Calendar events for this day.  canvasRenderableCalendarEvents:
        // the "what's on at 3pm" question should not return phantom
        // blocks for absorbed-into-parent todos — the user perceives
        // the parent event, not the absorbed item separately, so
        // the agent reading the schedule should agree.
        let calEvents = store.canvasRenderableCalendarEvents.filter { event in
            guard let range = event.primaryTimeRange else { return false }
            return range.start < dayEnd && range.end > dayStart
        }

        // Todos with deadlines on this day
        let todosWithDeadline = store.activeEvents.filter { event in
            guard let deadline = event.deadline else { return false }
            return calendar.isDate(deadline, inSameDayAs: date)
        }

        var result: [String: Any] = [
            "date": dateOnly.string(from: date),
            "calendarEvents": calEvents.map { event -> [String: Any] in
                var item: [String: Any] = ["id": event.id.uuidString, "title": event.title]
                if let range = event.primaryTimeRange {
                    item["startTime"] = displayDateTime.string(from: range.start)
                    item["endTime"] = displayDateTime.string(from: range.end)
                }
                if !event.type.isEmpty { item["type"] = event.type }
                return item
            },
            "todosWithDeadline": todosWithDeadline.map { event -> [String: Any] in
                [
                    "id": event.id.uuidString,
                    "title": event.title,
                    "priority": event.priority,
                    "deadline": displayDateTime.string(from: event.deadline!),
                ]
            },
        ]
        result["calendarEventCount"] = calEvents.count
        result["todoDeadlineCount"] = todosWithDeadline.count

        let resultData = try? JSONSerialization.data(withJSONObject: result)
        return String(data: resultData ?? Data(), encoding: .utf8) ?? "{}"
    }

    private static func executeGetUserData(args: [String: Any], store: EventStore) -> String {
        let days = args["days"] as? Int ?? 30
        let calendar = Calendar.current
        let now = Date()
        let cutoff = calendar.date(byAdding: .day, value: -days, to: now)!

        // All todos (active + completed)
        let allTodos = store.events
        let todosData: [[String: Any]] = allTodos.map { event in
            var item: [String: Any] = [
                "id": event.id.uuidString,
                "title": event.title,
                "status": event.status.rawValue,
                "priority": event.priority,
                "isDone": event.isDone,
                "createdAt": displayDateTime.string(from: event.createdAt),
            ]
            if !event.note.isEmpty { item["note"] = event.note }
            if !event.tags.isEmpty { item["tags"] = event.tags }
            if !event.type.isEmpty { item["type"] = event.type }
            if let deadline = event.deadline { item["deadline"] = displayDateTime.string(from: deadline) }
            if let completeAt = event.completeAt { item["completedAt"] = displayDateTime.string(from: completeAt) }
            return item
        }

        // Calendar events within the date range.  Deliberately
        // `rawCalendarEvents` (NOT canvasRenderable): this tool is a
        // data-export shape — same intent as "give the agent the full
        // user dataset so it can reason about it", absorbed todos
        // are part of that dataset.
        let calendarEvents = store.rawCalendarEvents.filter { event in
            guard let range = event.primaryTimeRange else { return false }
            return range.start >= cutoff
        }
        let calendarData: [[String: Any]] = calendarEvents.map { event in
            var item: [String: Any] = [
                "id": event.id.uuidString,
                "title": event.title,
                "createdAt": displayDateTime.string(from: event.createdAt),
            ]
            if let range = event.primaryTimeRange {
                item["startTime"] = displayDateTime.string(from: range.start)
                item["endTime"] = displayDateTime.string(from: range.end)
                item["durationMinutes"] = Int(range.end.timeIntervalSince(range.start) / 60)
            }
            if !event.type.isEmpty { item["type"] = event.type }
            if !event.tags.isEmpty { item["tags"] = event.tags }
            if !event.note.isEmpty { item["note"] = event.note }
            if event.isAllDay { item["isAllDay"] = true }
            // Surface absorption so the LLM can dedupe / reason
            // about parent ↔ child rather than treating each absorbed
            // todo as an independent calendar entry.
            if let parent = event.absorbedIntoEventID {
                item["absorbedIntoEventID"] = parent.uuidString
            }
            return item
        }

        // `calendarEventCount` reports the canvas-visible count so it
        // agrees with `AgentService.systemPrompt`'s count and with
        // the user's perception. `rawCalendarEventCount` is exposed
        // separately for the LLM that wants to know "how many entries
        // in raw including absorbed children".
        let canvasCount = calendarEvents.filter { $0.absorbedIntoEventID == nil }.count
        let result: [String: Any] = [
            "queryDays": days,
            "queryFrom": displayDateTime.string(from: cutoff),
            "queryTo": displayDateTime.string(from: now),
            "todos": todosData,
            "todoCount": todosData.count,
            "calendarEvents": calendarData,
            "calendarEventCount": canvasCount,
            "rawCalendarEventCount": calendarData.count,
        ]

        let resultData = try? JSONSerialization.data(withJSONObject: result)
        return String(data: resultData ?? Data(), encoding: .utf8) ?? "{}"
    }

    // MARK: - Helpers

    /// How an optional date-valued tool argument was supplied.
    ///
    /// JSON `null` arrives from JSONSerialization as `NSNull`, which is a
    /// present key — distinct from the key being absent. Absent means
    /// "leave the field alone"; null means "explicitly clear it". Anything
    /// present that does not parse to a date is `.invalid` and must reject
    /// the call — it must never silently become nil.
    private enum DateArgument {
        case absent
        case remove
        case set(Date)
        case invalid
    }

    private static func dateArgument(_ args: [String: Any], key: String) -> DateArgument {
        guard let raw = args[key] else { return .absent }
        if raw is NSNull { return .remove }
        if let string = raw as? String, let date = parseDate(string) { return .set(date) }
        return .invalid
    }

    private static func parseDate(_ string: String) -> Date? {
        if let d = dateTime.date(from: string) { return d }
        if let d = dateOnly.date(from: string) { return d }
        if let d = iso8601.date(from: string) { return d }
        return nil
    }

    private static func jsonResult(success: Bool, message: String, data: [String: Any]? = nil) -> String {
        var result: [String: Any] = ["success": success, "message": message]
        if let data { result.merge(data) { _, new in new } }
        let jsonData = try? JSONSerialization.data(withJSONObject: result)
        return String(data: jsonData ?? Data(), encoding: .utf8) ?? "{}"
    }
}
