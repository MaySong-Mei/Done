import Foundation

enum EventLogTemplateRegistry {
    static let definitions: [EventLogTemplateDefinition] = [
        EventLogTemplateDefinition(
            id: .deepWork,
            title: "Deep Work",
            familyTitle: "Work",
            fields: [
                EventLogTemplateFieldDefinition(
                    id: "outcome",
                    title: "Outcome",
                    kind: .singleSelect,
                    options: [
                        .init(id: "shipped", title: "Shipped"),
                        .init(id: "progressed", title: "Progressed"),
                        .init(id: "blocked", title: "Blocked")
                    ]
                ),
                EventLogTemplateFieldDefinition(id: "focusQuality", title: "Focus Quality", kind: .rating),
                EventLogTemplateFieldDefinition(
                    id: "mainDistraction",
                    title: "Main Distraction",
                    kind: .singleSelect,
                    options: [
                        .init(id: "none", title: "None"),
                        .init(id: "messages", title: "Messages"),
                        .init(id: "meetings", title: "Meetings"),
                        .init(id: "context_switching", title: "Context Switching"),
                        .init(id: "low_energy", title: "Low Energy")
                    ]
                ),
                EventLogTemplateFieldDefinition(
                    id: "nextStep",
                    title: "Next Step",
                    kind: .shortText,
                    placeholder: "What should happen next?"
                )
            ]
        ),
        EventLogTemplateDefinition(
            id: .meeting,
            title: "Meeting",
            familyTitle: "Work",
            fields: [
                EventLogTemplateFieldDefinition(
                    id: "meetingResult",
                    title: "Result",
                    kind: .singleSelect,
                    options: [
                        .init(id: "decision_made", title: "Decision Made"),
                        .init(id: "alignment_reached", title: "Alignment Reached"),
                        .init(id: "blocked", title: "Blocked"),
                        .init(id: "info_shared", title: "Info Shared")
                    ]
                ),
                EventLogTemplateFieldDefinition(
                    id: "actionItems",
                    title: "Action Items",
                    kind: .longText,
                    placeholder: "Capture follow-up items"
                ),
                EventLogTemplateFieldDefinition(
                    id: "followUpNeeded",
                    title: "Follow-up Needed",
                    kind: .singleSelect,
                    options: [
                        .init(id: "no", title: "No"),
                        .init(id: "yes_me", title: "Yes, me"),
                        .init(id: "yes_others", title: "Yes, others")
                    ]
                ),
                EventLogTemplateFieldDefinition(
                    id: "energyAfter",
                    title: "Energy After",
                    kind: .singleSelect,
                    options: [
                        .init(id: "energized", title: "Energized"),
                        .init(id: "neutral", title: "Neutral"),
                        .init(id: "drained", title: "Drained")
                    ]
                )
            ]
        ),
        EventLogTemplateDefinition(
            id: .workout,
            title: "Workout",
            familyTitle: "Exercise",
            fields: [
                EventLogTemplateFieldDefinition(
                    id: "activityKind",
                    title: "Activity",
                    kind: .singleSelect,
                    options: [
                        .init(id: "run", title: "Run"),
                        .init(id: "strength", title: "Strength"),
                        .init(id: "walk", title: "Walk"),
                        .init(id: "cycle", title: "Cycle"),
                        .init(id: "yoga", title: "Yoga"),
                        .init(id: "other", title: "Other")
                    ]
                ),
                EventLogTemplateFieldDefinition(id: "intensity", title: "Intensity", kind: .rating),
                EventLogTemplateFieldDefinition(
                    id: "bodyState",
                    title: "Body State",
                    kind: .multiSelect,
                    options: [
                        .init(id: "strong", title: "Strong"),
                        .init(id: "normal", title: "Normal"),
                        .init(id: "tired", title: "Tired"),
                        .init(id: "sore", title: "Sore"),
                        .init(id: "refreshed", title: "Refreshed")
                    ]
                ),
                EventLogTemplateFieldDefinition(
                    id: "keyMetric",
                    title: "Key Metric",
                    kind: .shortText,
                    placeholder: "5km, 3 sets, 45 min zone 2"
                )
            ]
        ),
        EventLogTemplateDefinition(
            id: .studySession,
            title: "Study Session",
            familyTitle: "Study",
            fields: [
                EventLogTemplateFieldDefinition(
                    id: "studyMode",
                    title: "Mode",
                    kind: .singleSelect,
                    options: [
                        .init(id: "reading", title: "Reading"),
                        .init(id: "course", title: "Course"),
                        .init(id: "practice", title: "Practice"),
                        .init(id: "review", title: "Review"),
                        .init(id: "language", title: "Language"),
                        .init(id: "other", title: "Other")
                    ]
                ),
                EventLogTemplateFieldDefinition(id: "understanding", title: "Understanding", kind: .rating),
                EventLogTemplateFieldDefinition(
                    id: "whatLearned",
                    title: "What Learned",
                    kind: .longText,
                    placeholder: "Capture the key takeaway"
                ),
                EventLogTemplateFieldDefinition(
                    id: "nextReview",
                    title: "Next Review",
                    kind: .shortText,
                    placeholder: "What should you revisit next?"
                )
            ]
        ),
        EventLogTemplateDefinition(
            id: .personalCare,
            title: "Personal Care",
            familyTitle: "Personal",
            fields: [
                EventLogTemplateFieldDefinition(
                    id: "careKind",
                    title: "Care Type",
                    kind: .singleSelect,
                    options: [
                        .init(id: "sleep", title: "Sleep"),
                        .init(id: "rest", title: "Rest"),
                        .init(id: "meal", title: "Meal"),
                        .init(id: "hygiene", title: "Hygiene"),
                        .init(id: "medical", title: "Medical"),
                        .init(id: "reset", title: "Reset"),
                        .init(id: "other", title: "Other")
                    ]
                ),
                EventLogTemplateFieldDefinition(
                    id: "feltBetterAfter",
                    title: "Felt Better After",
                    kind: .singleSelect,
                    options: [
                        .init(id: "yes", title: "Yes"),
                        .init(id: "partly", title: "Partly"),
                        .init(id: "no", title: "No")
                    ]
                ),
                EventLogTemplateFieldDefinition(
                    id: "stateAfter",
                    title: "State After",
                    kind: .multiSelect,
                    options: [
                        .init(id: "calm", title: "Calm"),
                        .init(id: "refreshed", title: "Refreshed"),
                        .init(id: "neutral", title: "Neutral"),
                        .init(id: "tired", title: "Tired"),
                        .init(id: "stressed", title: "Stressed")
                    ]
                ),
                EventLogTemplateFieldDefinition(
                    id: "followUp",
                    title: "Follow-up",
                    kind: .shortText,
                    placeholder: "Anything else needed?"
                )
            ]
        )
    ]

    static var groupedDefinitions: [(familyTitle: String, templates: [EventLogTemplateDefinition])] {
        Dictionary(grouping: definitions, by: \.familyTitle)
            .keys
            .sorted()
            .map { family in
                (familyTitle: family, templates: definitions.filter { $0.familyTitle == family })
            }
    }

    static func definition(for id: EventLogTemplateID) -> EventLogTemplateDefinition? {
        definitions.first { $0.id == id }
    }

    static func title(for rawID: String?) -> String? {
        guard let rawID, let id = EventLogTemplateID(rawValue: rawID) else { return nil }
        return definition(for: id)?.title
    }

    static func fieldTitle(templateID: EventLogTemplateID, fieldID: String) -> String? {
        definition(for: templateID)?.fields.first(where: { $0.id == fieldID })?.title
    }

    static func optionTitle(templateID: EventLogTemplateID, fieldID: String, optionID: String) -> String? {
        definition(for: templateID)?
            .fields
            .first(where: { $0.id == fieldID })?
            .options
            .first(where: { $0.id == optionID })?
            .title
    }
}

extension EventLogTemplateDefinition {
    func filteredAnswers(_ answers: [String: EventLogAnswerValue]) -> [String: EventLogAnswerValue] {
        let validIDs = Set(fields.map(\.id))
        return answers.filter { validIDs.contains($0.key) }
    }
}
