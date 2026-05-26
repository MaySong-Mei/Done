import SwiftUI

struct CalendarEventChatView: View {
    private static let contextSeedPrefix = "[CalendarEventContextSeed]"

    let occurrence: CalendarEventOccurrenceContext

    @EnvironmentObject private var store: EventStore
    @EnvironmentObject private var agentRuntime: AgentRuntime
    @Environment(\.dismiss) private var dismiss

    @StateObject private var agentService = AgentService()
    @State private var inputText = ""
    @State private var didInitializeConversation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messageList
            Divider()
            inputBar
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .semibold))
                }
            }
        }
        .onAppear {
            agentService.eventStore = store
            agentService.agentRuntime = agentRuntime
            initializeConversationIfNeeded()
        }
    }
}

private extension CalendarEventChatView {
    var resolvedEvent: Event? {
        calendarResolvedEventForOccurrenceContext(occurrence, in: store.rawCalendarEvents)
    }

    var occurrenceRange: Event.TimeRange? {
        guard let event = resolvedEvent else { return nil }
        return calendarOccurrenceDisplayRange(event: event, occurrenceDate: occurrence.occurrenceDate)
    }

    var navigationTitle: String {
        if let event = resolvedEvent {
            return event.title.isEmpty ? "Event Chat" : event.title
        }
        return "Event Chat"
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let event = resolvedEvent, !event.type.isEmpty {
                    Text(event.type)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(EventTypeTemplateStore.color(for: event.type).opacity(0.2))
                        .foregroundStyle(EventTypeTemplateStore.color(for: event.type))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                Text(resolvedEvent?.title ?? "Deleted Event")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }

            if let range = occurrenceRange {
                Text(rangeSummary(range))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
    }

    var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(visibleMessages) { message in
                        MessageBubbleView(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .onChange(of: agentService.messages.count) {
                if let last = visibleMessages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    var visibleMessages: [ChatMessage] {
        let nonToolResults = agentService.messages.filter { $0.role != .toolResult }
        guard let first = nonToolResults.first, first.role == .user else { return nonToolResults }
        if first.content.hasPrefix(Self.contextSeedPrefix) {
            return Array(nonToolResults.dropFirst())
        }
        return nonToolResults
    }

    var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Message about this event...", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(canSend ? Color.accentColor : Color(.systemGray4))
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !agentService.isProcessing
    }

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        agentService.sendMessage(text)
    }

    func initializeConversationIfNeeded() {
        guard !didInitializeConversation else { return }
        didInitializeConversation = true

        if let existingID = store.feedbackRecord(for: occurrence)?.chatConversationID,
           agentService.conversations.contains(where: { $0.id == existingID }) {
            agentService.switchToConversation(existingID)
            return
        }

        agentService.createNewConversation()
        if let newID = agentService.currentConversationID {
            store.setChatConversationID(newID, for: occurrence)
        }

        let seedPrompt = buildContextSeedPrompt()
        agentService.sendMessage(seedPrompt)
    }

    func buildContextSeedPrompt() -> String {
        let event = resolvedEvent
        let range = occurrenceRange
        let feedback = store.feedbackRecord(for: occurrence)
        let logRecord = store.logRecord(for: occurrence)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        var lines: [String] = [
            "\(Self.contextSeedPrefix) You are helping the user reflect on a specific calendar event occurrence.",
            "Focus on this occurrence unless the user asks broader questions."
        ]

        if let event {
            lines.append("Event title: \(event.title)")
            if !event.type.isEmpty { lines.append("Event type: \(event.type)") }
            if !event.location.isEmpty { lines.append("Location: \(event.location)") }
            if !event.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("Event note: \(event.note)")
            }
        }
        if let range {
            lines.append("Occurrence time: \(formatter.string(from: range.start)) to \(formatter.string(from: range.end))")
        } else {
            lines.append("Occurrence date: \(formatter.string(from: occurrence.occurrenceDate))")
        }

        if let logRecord {
            if let templateTitle = EventLogTemplateRegistry.title(for: logRecord.selectedTemplateID ?? logRecord.suggestedTemplateID) {
                lines.append("Log template: \(templateTitle)")
            }
            if let completionStatus = logRecord.completionStatus {
                lines.append("Completion: \(completionStatus.title)")
            }
            if let actualDurationMinutes = logRecord.actualDurationMinutes {
                lines.append("Actual duration: \(actualDurationMinutes) min")
            }
            if !logRecord.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("Summary: \(logRecord.summary)")
            }
            if !logRecord.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("Log note: \(logRecord.note)")
            }
            if let effort = logRecord.effort {
                lines.append("Effort (1-5): \(effort)")
            }
            if !logRecord.emotions.isEmpty {
                lines.append("Emotions: \(logRecord.emotions.joined(separator: ", "))")
            }
            if !logRecord.behaviors.isEmpty {
                lines.append("Behaviors: \(logRecord.behaviors.joined(separator: ", "))")
            }
            if let selectedTemplateID = logRecord.selectedTemplateID.flatMap(EventLogTemplateID.init(rawValue:)) {
                for field in EventLogTemplateRegistry.definition(for: selectedTemplateID)?.fields ?? [] {
                    guard let answer = logRecord.templateAnswers[field.id] else { continue }
                    lines.append("\(field.title): \(formattedAnswer(answer, templateID: selectedTemplateID, fieldID: field.id))")
                }
            }
            let timelineNotes = logRecord.timelineItems.compactMap(\.noteValue)
            if !timelineNotes.isEmpty {
                lines.append("Recent timeline notes:")
                for log in timelineNotes.sorted(by: { $0.createdAt > $1.createdAt }).prefix(5) {
                    lines.append("- \(formatter.string(from: log.createdAt)): \(log.text)")
                }
            }
            let interruptRefs = logRecord.timelineItems.compactMap(\.interruptReferenceValue)
            if !interruptRefs.isEmpty {
                lines.append("Interrupt events:")
                for reference in interruptRefs.prefix(5) {
                    if let interruptEvent = store.findCalendarEvent(id: reference.childEventID),
                       let childRange = interruptEvent.primaryTimeRange {
                        let state = interruptEvent.interruptRelation?.state.rawValue ?? "unknown"
                        lines.append("- \(interruptEvent.title): \(formatter.string(from: childRange.start)) to \(formatter.string(from: childRange.end)) [\(state)]")
                    }
                }
            }
        } else if let feedback {
            if let effort = feedback.effort {
                lines.append("Effort (1-5): \(effort)")
            }
            if !feedback.emotions.isEmpty {
                lines.append("Emotions: \(feedback.emotions.joined(separator: ", "))")
            }
            if !feedback.behaviors.isEmpty {
                lines.append("Behaviors: \(feedback.behaviors.joined(separator: ", "))")
            }
            if !feedback.selfNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append("Self note: \(feedback.selfNote)")
            }
            if !feedback.logs.isEmpty {
                lines.append("Recent logs:")
                for log in feedback.logs.sorted(by: { $0.createdAt > $1.createdAt }).prefix(5) {
                    lines.append("- \(formatter.string(from: log.createdAt)): \(log.text)")
                }
            }
        }

        lines.append("Start by briefly acknowledging the event context and offer help with reflection, planning, or follow-up.")
        return lines.joined(separator: "\n")
    }

    func formattedAnswer(_ answer: EventLogAnswerValue, templateID: EventLogTemplateID, fieldID: String) -> String {
        switch answer {
        case .string(let value):
            return EventLogTemplateRegistry.optionTitle(templateID: templateID, fieldID: fieldID, optionID: value) ?? value
        case .strings(let values):
            return values
                .map { EventLogTemplateRegistry.optionTitle(templateID: templateID, fieldID: fieldID, optionID: $0) ?? $0 }
                .joined(separator: ", ")
        case .int(let value):
            return String(value)
        }
    }

    func rangeSummary(_ range: Event.TimeRange) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        let timeFormatter = DateFormatter()
        if AppTimeFormat.current.is24 {
            timeFormatter.dateFormat = "H:mm"
        } else {
            timeFormatter.locale = Locale(identifier: "en_US_POSIX")
            timeFormatter.dateFormat = "h:mm a"
            timeFormatter.amSymbol = "am"
            timeFormatter.pmSymbol = "pm"
        }
        let sameDay = Calendar.current.isDate(range.start, inSameDayAs: range.end)
        if sameDay {
            return "\(dateFormatter.string(from: range.start)) • \(timeFormatter.string(from: range.start)) - \(timeFormatter.string(from: range.end))"
        }
        return "\(dateFormatter.string(from: range.start)) - \(dateFormatter.string(from: range.end))"
    }
}
