import Foundation

/// Lightweight event snapshot shared between the main app and widget via App Group UserDefaults.
struct SharedEventSnapshot: Codable {
    var id: UUID
    var title: String
    var type: String
    var colorHex: String?
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var isDone: Bool
    var isInterrupt: Bool?
    var parentEventID: UUID?
}

enum SharedWidgetData {
    static let appGroupID = "group.wordless.shiqiliuyifanmei.app"
    static let snapshotKey = "widgetEventSnapshots"
    static let lastUpdatedKey = "widgetLastUpdated"

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    static let timeFormatKey = "widgetTimeFormat"
    static let languageKey = "widgetLanguage"

    static func write(events: [SharedEventSnapshot], timeFormat: String = "24h", language: String = "en") {
        guard let defaults = sharedDefaults else { return }
        if let data = try? JSONEncoder().encode(events) {
            defaults.set(data, forKey: snapshotKey)
            defaults.set(Date(), forKey: lastUpdatedKey)
            defaults.set(timeFormat, forKey: timeFormatKey)
            defaults.set(language, forKey: languageKey)
        }
    }

    static func read() -> [SharedEventSnapshot] {
        guard let defaults = sharedDefaults,
              let data = defaults.data(forKey: snapshotKey),
              let events = try? JSONDecoder().decode([SharedEventSnapshot].self, from: data) else {
            return []
        }
        return events
    }
}
