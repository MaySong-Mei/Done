import Foundation

/// Visual style for the in-event focus protagonist (the surface that
/// shows the current focused event). Three variants under experiment
/// on the focus-mode-contract branch:
///
/// - `text`: text-driven layout (type chip / 44pt title / 36pt mono
///   "Xm left" / time range). The shipped style; baseline.
/// - `cardHero`: a single large event card whose visual treatment
///   matches the calendar's event blocks (type-color fill + border).
///   All info — title, "Xm left", time range — lives inside the
///   card. The card *is* the event.
/// - `textPlusBlock`: text protagonist preserved on top, plus a
///   compact mini event block below in the calendar's visual
///   vocabulary. Two layers, dual purpose.
///
/// Stored as a raw string in UserDefaults via
/// `AppSettingsKeys.focusProtagonistStyle`.
enum FocusProtagonistStyle: String, CaseIterable, Identifiable, Codable {
    case text
    case cardHero
    case textPlusBlock

    var id: String { rawValue }

    var label: String {
        switch self {
        case .text: return "Text"
        case .cardHero: return "Event Card"
        case .textPlusBlock: return "Text + Block"
        }
    }

    var summary: String {
        switch self {
        case .text:
            return "Big title + status text"
        case .cardHero:
            return "Single colored card containing all event info"
        case .textPlusBlock:
            return "Text + mini event block below"
        }
    }
}
