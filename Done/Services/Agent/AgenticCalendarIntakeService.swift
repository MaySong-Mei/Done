import Foundation

struct AgenticInputImage: Identifiable, Hashable {
    var id: UUID
    var data: Data
    var mimeType: String

    init(id: UUID = UUID(), data: Data, mimeType: String = "image/jpeg") {
        self.id = id
        self.data = data
        self.mimeType = mimeType
    }
}

struct AgenticCalendarContext: Hashable {
    var visibleDate: Date
    var nearbyEventsSummary: String
    var now: Date
    var timeZoneIdentifier: String

    init(
        visibleDate: Date,
        nearbyEventsSummary: String,
        now: Date = Date(),
        timeZoneIdentifier: String = TimeZone.current.identifier
    ) {
        self.visibleDate = visibleDate
        self.nearbyEventsSummary = nearbyEventsSummary
        self.now = now
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}

struct AgenticCalendarAutofillResult: Hashable {
    var title: String
    var typeTitle: String
    var note: String
    var location: String
    var startTime: Date
    var endTime: Date
    var isAllDay: Bool
    var repeatUnit: Event.RepeatUnit
    var repeatInterval: Int
    var repeatEndType: Event.RepeatEndType
    var repeatEndDate: Date?
    var repeatEndCount: Int?
    var confidence: Double
    var warnings: [String]
    var usedVision: Bool
    var providerName: String
    var providerModel: String?

    func toFormData(agenticIntake: AgenticIntakeRecord? = nil) -> CalendarEventFormData {
        CalendarEventFormData(
            title: title,
            typeTitle: typeTitle,
            note: note,
            location: location,
            startTime: startTime,
            endTime: endTime,
            isAllDay: isAllDay,
            repeatUnit: repeatUnit,
            repeatInterval: repeatInterval,
            repeatEndType: repeatEndType,
            repeatEndDate: repeatEndDate,
            repeatEndCount: repeatEndCount,
            agenticIntake: agenticIntake
        )
    }
}

enum AgenticCalendarIntakeError: LocalizedError {
    case emptyInput
    case invalidJSON(String)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "Please enter a description or add images first."
        case .invalidJSON(let raw):
            return "The AI response could not be parsed as event data. Raw response: \(raw.prefix(160))"
        }
    }
}

final class AgenticCalendarIntakeService {
    private let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func generateAutofill(
        rawText: String,
        selectedImages: [AgenticInputImage],
        pendingCreate: PendingEventCreation,
        calendarContext: AgenticCalendarContext,
        availableTypes: [String]
    ) async throws -> AgenticCalendarAutofillResult {
        let trimmedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedText.isEmpty && selectedImages.isEmpty {
            throw AgenticCalendarIntakeError.emptyInput
        }

        let providerBundle = try buildProviderBundle()
        let prompt = buildPrompt(
            rawText: trimmedText,
            selectedImages: selectedImages,
            pendingCreate: pendingCreate,
            context: calendarContext,
            availableTypes: availableTypes
        )

        let usedVision = !selectedImages.isEmpty && providerBundle.provider.supportsVision
        let response: LLMResponse
        if usedVision {
            let visionRequest = LLMVisionRequest(
                messages: [LLMVisionMessage(
                    role: .user,
                    text: prompt,
                    images: selectedImages.map { LLMVisionImage(data: $0.data, mimeType: $0.mimeType) }
                )],
                systemPrompt: systemPrompt
            )
            response = try await providerBundle.provider.sendVision(visionRequest)
        } else {
            let textPrompt: String
            if !selectedImages.isEmpty {
                textPrompt = prompt + "\n\nImage count (not analyzable by current provider): \(selectedImages.count)"
            } else {
                textPrompt = prompt
            }
            let request = LLMRequest(
                messages: [LLMMessage(role: .user, content: textPrompt)],
                tools: [],
                systemPrompt: systemPrompt
            )
            response = try await providerBundle.provider.send(request)
        }

        guard let content = response.content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgenticCalendarIntakeError.invalidJSON("<empty>")
        }

        var parsed = try parseResult(
            from: content,
            defaultType: availableTypes.first ?? "Study",
            fallbackRange: pendingCreate.timeRange,
            providerName: providerBundle.providerName,
            providerModel: providerBundle.modelName,
            usedVision: usedVision
        )

        if !selectedImages.isEmpty && !usedVision {
            parsed.warnings.append("Current provider does not support image analysis. Images were saved but not used for AI inference.")
        }

        return AgenticCalendarAutofillNormalizer.normalize(
            parsed,
            pendingCreate: pendingCreate,
            context: calendarContext
        )
    }

    private var systemPrompt: String {
        "You are a calendar event autofill assistant. Return JSON only, no markdown, no prose."
    }

    private func buildPrompt(
        rawText: String,
        selectedImages: [AgenticInputImage],
        pendingCreate: PendingEventCreation,
        context: AgenticCalendarContext,
        availableTypes: [String]
    ) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let rangeStart = iso.string(from: pendingCreate.timeRange.start)
        let rangeEnd = iso.string(from: pendingCreate.timeRange.end)
        let visible = iso.string(from: context.visibleDate)
        let now = iso.string(from: context.now)
        let typeList = availableTypes.isEmpty ? "[]" : availableTypes.joined(separator: ", ")
        let sourceRule: String
        switch pendingCreate.source {
        case .dragCreate:
            sourceRule = "Creation source: dragCreate. The provided drag time range is a HARD CONSTRAINT. Keep exact startTime and endTime from the drag range; infer only title/type/note/location/repeat."
        case .quickAdd:
            sourceRule = "Creation source: quickAdd. You may infer date and time (can be non-today)."
        case .classicFallback:
            sourceRule = "Creation source: classicFallback. Prefer conservative defaults."
        }

        return """
        Fill a calendar event from user input for the Done app.

        User raw text:
        \(rawText.isEmpty ? "<empty>" : rawText)

        Image count attached: \(selectedImages.count)
        Timezone: \(context.timeZoneIdentifier)
        Current time: \(now)
        Calendar visible date (anchor): \(visible)
        Drag/default proposed time range start: \(rangeStart)
        Drag/default proposed time range end: \(rangeEnd)
        \(sourceRule)

        Available event types (prefer one of these only when it is a genuinely good semantic match): \(typeList)

        Type selection rules:
        - If the user explicitly specifies a type/category name (for example "type use Reading"), preserve that exact typeTitle unless it is clearly invalid.
        - If no available type matches well, you MAY propose a new short human-readable typeTitle (2-24 characters) instead of forcing a bad match.
        - Do not use long phrases, URLs, or full sentences as typeTitle.

        Nearby schedule summary (avoid obvious conflicts if possible):
        \(context.nearbyEventsSummary.isEmpty ? "<none>" : context.nearbyEventsSummary)

        Return a JSON object with exactly these fields:
        {
          "title": string,
          "typeTitle": string,
          "note": string,
          "location": string,
          "startTime": string (ISO8601),
          "endTime": string (ISO8601),
          "isAllDay": boolean,
          "repeatUnit": string (none|day|week|month|year),
          "repeatInterval": integer,
          "repeatEndType": string (none|onDate|afterCount),
          "repeatEndDate": string|null (ISO8601 date or datetime),
          "repeatEndCount": integer|null,
          "confidence": number (0-1),
          "warnings": string[]
        }

        Return JSON only.
        """
    }

    private func parseResult(
        from raw: String,
        defaultType: String,
        fallbackRange: Event.TimeRange,
        providerName: String,
        providerModel: String?,
        usedVision: Bool
    ) throws -> AgenticCalendarAutofillResult {
        let jsonText = extractJSONObject(from: raw)
        guard let data = jsonText.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgenticCalendarIntakeError.invalidJSON(raw)
        }

        let title = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let typeTitle = (json["typeTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = json["note"] as? String ?? ""
        let location = json["location"] as? String ?? ""
        let startTime = parseDate(json["startTime"] as? String) ?? fallbackRange.start
        let endTime = parseDate(json["endTime"] as? String) ?? fallbackRange.end
        let isAllDay = json["isAllDay"] as? Bool ?? false
        let repeatUnit = Event.RepeatUnit(rawValue: json["repeatUnit"] as? String ?? "") ?? .none
        let repeatInterval = (json["repeatInterval"] as? Int) ?? 1
        let repeatEndType = Event.RepeatEndType(rawValue: json["repeatEndType"] as? String ?? "") ?? .none
        let repeatEndDate = parseDate(json["repeatEndDate"] as? String)
        let repeatEndCount = json["repeatEndCount"] as? Int
        let confidence = (json["confidence"] as? Double) ?? 0.5
        let warnings = json["warnings"] as? [String] ?? []

        return AgenticCalendarAutofillResult(
            title: (title?.isEmpty == false ? title! : "Untitled Event"),
            typeTitle: (typeTitle?.isEmpty == false ? typeTitle! : defaultType),
            note: note,
            location: location,
            startTime: startTime,
            endTime: endTime,
            isAllDay: isAllDay,
            repeatUnit: repeatUnit,
            repeatInterval: repeatInterval,
            repeatEndType: repeatEndType,
            repeatEndDate: repeatEndDate,
            repeatEndCount: repeatEndCount,
            confidence: confidence,
            warnings: warnings,
            usedVision: usedVision,
            providerName: providerName,
            providerModel: providerModel
        )
    }

    private func parseDate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        if let date = iso8601.date(from: string) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: string) {
            return date
        }
        let dateOnly = DateFormatter()
        dateOnly.locale = Locale(identifier: "en_US_POSIX")
        dateOnly.timeZone = .current
        dateOnly.dateFormat = "yyyy-MM-dd"
        return dateOnly.date(from: string)
    }

    private func extractJSONObject(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.first == "{" && trimmed.last == "}" {
            return trimmed
        }
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") {
            return String(trimmed[start...end])
        }
        return trimmed
    }

    private struct ProviderBundle {
        let provider: any LLMProvider
        let providerName: String
        let modelName: String?
    }

    private func buildProviderBundle() throws -> ProviderBundle {
        let providerType = UserDefaults.standard.string(forKey: "agentProvider") ?? "claude"
        let apiKey = UserDefaults.standard.string(forKey: "agentAPIKey") ?? ""

        guard !apiKey.isEmpty else {
            throw LLMError.noAPIKey
        }

        switch providerType {
        case "openai":
            let provider = OpenAIProvider(apiKey: apiKey)
            return ProviderBundle(provider: provider, providerName: "openai", modelName: provider.model)
        case "deepseek":
            let provider = DeepSeekProvider(apiKey: apiKey)
            return ProviderBundle(provider: provider, providerName: "deepseek", modelName: provider.model)
        default:
            let provider = ClaudeProvider(apiKey: apiKey)
            return ProviderBundle(provider: provider, providerName: "claude", modelName: provider.model)
        }
    }
}

struct AgenticCalendarAutofillNormalizer {
    static func normalize(
        _ input: AgenticCalendarAutofillResult,
        pendingCreate: PendingEventCreation,
        context: AgenticCalendarContext,
        calendar: Calendar = .current
    ) -> AgenticCalendarAutofillResult {
        var result = input
        var warnings = result.warnings

        result.title = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.title.isEmpty {
            result.title = "Untitled Event"
            warnings.append("Title was empty; used fallback title.")
        }

        result.typeTitle = result.typeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.typeTitle.isEmpty {
            result.typeTitle = "Study"
            warnings.append("Type was empty; used fallback type.")
        }

        switch pendingCreate.source {
        case .dragCreate:
            result.startTime = pendingCreate.timeRange.start
            result.endTime = pendingCreate.timeRange.end
            result.isAllDay = false
        case .quickAdd, .classicFallback:
            let dayDistance = abs(calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: context.visibleDate),
                to: calendar.startOfDay(for: result.startTime)
            ).day ?? 0)
            if dayDistance > 7 {
                result.startTime = pendingCreate.timeRange.start
                result.endTime = pendingCreate.timeRange.end
                warnings.append("AI proposed a date too far from the current calendar context; used quick-add fallback time.")
            }
        }

        if result.isAllDay {
            result.startTime = calendar.startOfDay(for: result.startTime)
            result.endTime = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: result.endTime))?.addingTimeInterval(-1)
                ?? result.startTime.addingTimeInterval(86399)
        } else {
            result.startTime = roundToQuarterHour(result.startTime, calendar: calendar)
            result.endTime = roundToQuarterHour(result.endTime, calendar: calendar)
        }

        if result.endTime <= result.startTime {
            let fallbackDuration = max(15 * 60, pendingCreate.timeRange.end.timeIntervalSince(pendingCreate.timeRange.start))
            result.endTime = result.startTime.addingTimeInterval(fallbackDuration)
            if !result.isAllDay {
                result.endTime = roundToQuarterHour(result.endTime, calendar: calendar)
                if result.endTime <= result.startTime {
                    result.endTime = result.startTime.addingTimeInterval(15 * 60)
                }
            }
            warnings.append("AI returned an invalid duration; adjusted end time.")
        }

        result.repeatInterval = min(max(result.repeatInterval, 1), 99)
        if result.repeatUnit == .none {
            result.repeatEndType = .none
            result.repeatEndDate = nil
            result.repeatEndCount = nil
        } else {
            switch result.repeatEndType {
            case .none:
                result.repeatEndDate = nil
                result.repeatEndCount = nil
            case .onDate:
                if result.repeatEndDate == nil {
                    result.repeatEndType = .none
                    warnings.append("Repeat end date was invalid and has been removed.")
                }
                result.repeatEndCount = nil
            case .afterCount:
                if let count = result.repeatEndCount {
                    result.repeatEndCount = min(max(count, 1), 999)
                } else {
                    result.repeatEndType = .none
                    warnings.append("Repeat end count was invalid and has been removed.")
                }
                result.repeatEndDate = nil
            }
        }

        result.confidence = min(max(result.confidence, 0), 1)
        result.warnings = NSOrderedSet(array: warnings).array.compactMap { $0 as? String }
        return result
    }

    static func roundToQuarterHour(_ date: Date, calendar: Calendar = .current) -> Date {
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let minute = components.minute ?? 0
        let rounded = Int((Double(minute) / 15.0).rounded() * 15.0)
        if rounded >= 60 {
            components.minute = 0
            components.second = 0
            let base = calendar.date(from: components) ?? date
            return calendar.date(byAdding: .hour, value: 1, to: base) ?? base
        }
        components.minute = rounded
        components.second = 0
        return calendar.date(from: components) ?? date
    }
}
