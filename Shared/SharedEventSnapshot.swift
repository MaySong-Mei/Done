import Foundation

/// Lightweight event snapshot shared between the main app and widget via App Group UserDefaults.
struct SharedEventSnapshot: Codable {
    var id: UUID
    var title: String
    var type: String
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var isDone: Bool
}

enum SharedWidgetData {
    static let appGroupID = "group.wordless.shiqiliuyifanmei.app"
    static let snapshotKey = "widgetEventSnapshots"
    static let lastUpdatedKey = "widgetLastUpdated"

    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    static func write(events: [SharedEventSnapshot]) {
        guard let defaults = sharedDefaults else { return }
        if let data = try? JSONEncoder().encode(events) {
            defaults.set(data, forKey: snapshotKey)
            defaults.set(Date(), forKey: lastUpdatedKey)
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
