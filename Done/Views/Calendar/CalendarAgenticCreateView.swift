import SwiftUI
import PhotosUI
import Combine

enum CalendarAgenticBannerState: Equatable, Identifiable {
    case analyzing(eventID: UUID)
    case failed(eventID: UUID, message: String)

    var id: String {
        switch self {
        case .analyzing(let eventID):
            return "analyzing-\(eventID.uuidString)"
        case .failed(let eventID, _):
            return "failed-\(eventID.uuidString)"
        }
    }
}

protocol AgenticCalendarAutofillGenerating {
    func generateAutofill(
        rawText: String,
        selectedImages: [AgenticInputImage],
        pendingCreate: PendingEventCreation,
        calendarContext: AgenticCalendarContext,
        availableTypes: [String]
    ) async throws -> AgenticCalendarAutofillResult
}

extension AgenticCalendarIntakeService: AgenticCalendarAutofillGenerating { }

@MainActor
final class CalendarAgenticCreateCoordinator: ObservableObject {
    @Published private(set) var inFlightEventIDs: Set<UUID> = []
    @Published var banner: CalendarAgenticBannerState?

    private let intakeService: any AgenticCalendarAutofillGenerating
    private let assetStore: AgenticIntakeAssetStore
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var inFlightSources: [UUID: AgenticCreateSource] = [:]
    private var bannerAutoDismissTask: Task<Void, Never>?

    init() {
        self.intakeService = AgenticCalendarIntakeService()
        self.assetStore = AgenticIntakeAssetStore()
    }

    init(
        intakeService: any AgenticCalendarAutofillGenerating,
        assetStore: AgenticIntakeAssetStore
    ) {
        self.intakeService = intakeService
        self.assetStore = assetStore
    }

    deinit {
        for task in tasks.values {
            task.cancel()
        }
    }

    func dismissBanner() {
        bannerAutoDismissTask?.cancel()
        bannerAutoDismissTask = nil
        banner = nil
    }

    @discardableResult
    func submitOptimisticCreate(
        rawText: String,
        selectedImages: [AgenticInputImage],
        pendingCreate: PendingEventCreation,
        calendarContext: AgenticCalendarContext,
        availableTypes: [String],
        uiWarnings: [String],
        applyRefinedContentToPlaceholder: Bool = false,
        store: EventStore
    ) -> Event {
        submitOptimisticCreate(
            rawText: rawText,
            selectedImages: selectedImages,
            pendingCreate: pendingCreate,
            calendarContext: calendarContext,
            availableTypes: availableTypes,
            uiWarnings: uiWarnings,
            applyRefinedContentToPlaceholder: applyRefinedContentToPlaceholder,
            agentRuntime: nil,
            store: store
        )
    }

    @discardableResult
    func submitOptimisticCreate(
        rawText: String,
        selectedImages: [AgenticInputImage],
        pendingCreate: PendingEventCreation,
        calendarContext: AgenticCalendarContext,
        availableTypes: [String],
        uiWarnings: [String],
        applyRefinedContentToPlaceholder: Bool = false,
        agentRuntime: AgentRuntime?,
        store: EventStore
    ) -> Event {
        let now = Date()
        let trimmedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = pendingCreate.timeRange
        let placeholderID = UUID()

        let intake = makePlaceholderIntakeRecord(
            eventID: placeholderID,
            rawText: trimmedText,
            selectedImages: selectedImages,
            source: pendingCreate.source,
            uiWarnings: uiWarnings,
            now: now
        )

        let placeholderEvent = Event(
            id: placeholderID,
            title: placeholderTitle(from: trimmedText),
            note: "",
            location: "",
            timeRanges: [range],
            repeatUnit: .none,
            isAllDay: false,
            repeatInterval: 1,
            repeatEndType: .none,
            type: placeholderType(from: availableTypes),
            agenticIntake: intake
        )

        store.addCalendarEvent(placeholderEvent)
        inFlightEventIDs.insert(placeholderID)
        inFlightSources[placeholderID] = pendingCreate.source
        if pendingCreate.source == .quickAdd {
            banner = .analyzing(eventID: placeholderID)
        }

        let draft = BackgroundAutofillDraft(
            rawText: trimmedText,
            selectedImages: selectedImages,
            pendingCreate: pendingCreate,
            calendarContext: calendarContext,
            availableTypes: availableTypes,
            applyRefinedContentToPlaceholder: applyRefinedContentToPlaceholder,
            agentRuntime: agentRuntime
        )

        tasks[placeholderID]?.cancel()
        tasks[placeholderID] = Task { [weak self] in
            await self?.runAutofill(eventID: placeholderID, draft: draft, store: store)
        }

        return placeholderEvent
    }

    private struct BackgroundAutofillDraft {
        var rawText: String
        var selectedImages: [AgenticInputImage]
        var pendingCreate: PendingEventCreation
        var calendarContext: AgenticCalendarContext
        var availableTypes: [String]
        var applyRefinedContentToPlaceholder: Bool
        var agentRuntime: AgentRuntime?
    }

    private func runAutofill(
        eventID: UUID,
        draft: BackgroundAutofillDraft,
        store: EventStore
    ) async {
        defer {
            tasks[eventID] = nil
        }

        do {
            let result = try await intakeService.generateAutofill(
                rawText: draft.rawText,
                selectedImages: draft.selectedImages,
                pendingCreate: draft.pendingCreate,
                calendarContext: draft.calendarContext,
                availableTypes: draft.availableTypes
            )
            await applyAutofillSuccess(
                eventID: eventID,
                result: result,
                source: draft.pendingCreate.source,
                applyRefinedContentToPlaceholder: draft.applyRefinedContentToPlaceholder,
                agentRuntime: draft.agentRuntime,
                store: store
            )
        } catch is CancellationError {
            await finishInFlight(eventID: eventID)
        } catch {
            await applyAutofillFailure(
                eventID: eventID,
                message: error.localizedDescription,
                store: store
            )
        }
    }

    private func applyAutofillSuccess(
        eventID: UUID,
        result: AgenticCalendarAutofillResult,
        source: AgenticCreateSource,
        applyRefinedContentToPlaceholder: Bool,
        agentRuntime: AgentRuntime?,
        store: EventStore
    ) async {
        guard let current = store.rawCalendarEvents.first(where: { $0.id == eventID }) else {
            await finishInFlight(eventID: eventID)
            return
        }

        var updated = current
        if applyRefinedContentToPlaceholder {
            updated.title = result.title
            updated.note = result.note
            updated.location = result.location
        }
        updated.type = result.typeTitle
        updated.suggestedLogTemplateID = result.suggestedLogTemplateID
        updated.suggestedLogTemplateConfidence = result.suggestedLogTemplateConfidence
        updated.suggestedLogTemplateUpdatedAt = result.suggestedLogTemplateID == nil ? nil : Date()
        updated.suggestedLogTemplateSource = result.suggestedLogTemplateID == nil ? nil : .agent

        let providerMetadata = AgenticProviderMetadata(
            provider: result.providerName,
            model: result.providerModel,
            usedVision: result.usedVision
        )
        updated.agenticIntake = mergedIntake(
            current.agenticIntake,
            providerMetadata: providerMetadata,
            warnings: result.warnings,
            processingPhase: .completed,
            failureMessage: nil
        )

        store.updateCalendarEvent(updated)

        if let agentRuntime {
            agentDecisionDebugLog("CalendarAgenticCreate post-autofill type review: eventID=\(eventID.uuidString) source=\(source.rawValue) updated.type='\(updated.type)'")
            let context = AgentDecisionContext(
                domain: .calendar,
                operationID: UUID(),
                sourceScreen: "CalendarAgenticCreate",
                conversationID: nil,
                relatedEventIDs: [eventID],
                payloadSummary: "Review inferred event type after Agentic create",
                metadata: [
                    "candidateType": updated.type,
                    "eventKind": "calendar",
                    "source": source.rawValue
                ]
            )
            Task { @MainActor in
                agentDecisionDebugLog("CalendarAgenticCreate calling operationCenter for eventID=\(eventID.uuidString)")
                await agentRuntime.operationCenter.maybeHandleMissingEventTypeTemplate(
                    for: eventID,
                    isCalendarEvent: true,
                    proposedType: updated.type,
                    store: store,
                    context: context
                )
            }
        }

        _ = source
        await finishInFlight(eventID: eventID)
    }

    private func applyAutofillFailure(
        eventID: UUID,
        message: String,
        store: EventStore
    ) async {
        if let current = store.rawCalendarEvents.first(where: { $0.id == eventID }) {
            var updated = current
            updated.agenticIntake = mergedIntake(
                current.agenticIntake,
                providerMetadata: current.agenticIntake?.providerMetadata,
                warnings: current.agenticIntake?.warnings ?? [],
                processingPhase: .failed,
                failureMessage: message
            )
            store.updateCalendarEvent(updated)
        }

        banner = .failed(eventID: eventID, message: message)
        await finishInFlight(eventID: eventID, preserveBanner: true)
        bannerAutoDismissTask?.cancel()
        bannerAutoDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.banner = nil
            if let current = store.rawCalendarEvents.first(where: { $0.id == eventID }),
               current.agenticIntake?.processingPhase == .failed {
                var updated = current
                updated.agenticIntake?.processingPhase = .completed
                updated.agenticIntake?.failureMessage = nil
                store.updateCalendarEvent(updated)
            }
        }
    }

    private func finishInFlight(
        eventID: UUID,
        preserveBanner: Bool = false
    ) async {
        inFlightEventIDs.remove(eventID)
        inFlightSources[eventID] = nil

        guard !preserveBanner else { return }

        if case .analyzing(let bannerEventID) = banner, bannerEventID == eventID {
            if let nextQuickAdd = inFlightSources.first(where: { $0.value == .quickAdd })?.key {
                banner = .analyzing(eventID: nextQuickAdd)
            } else {
                banner = nil
            }
        }
    }

    private func placeholderTitle(from rawText: String) -> String {
        let firstLine = rawText
            .split(whereSeparator: \.isNewline)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if firstLine.isEmpty {
            return "Analyzing..."
        }
        let maxLength = 40
        if firstLine.count > maxLength {
            let index = firstLine.index(firstLine.startIndex, offsetBy: maxLength)
            return String(firstLine[..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return firstLine
    }

    private func placeholderType(from availableTypes: [String]) -> String {
        let first = availableTypes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return first ?? "Study"
    }

    private func makePlaceholderIntakeRecord(
        eventID: UUID,
        rawText: String,
        selectedImages: [AgenticInputImage],
        source: AgenticCreateSource,
        uiWarnings: [String],
        now: Date
    ) -> AgenticIntakeRecord {
        let imported = selectedImages.map { AgenticIntakeAssetStore.ImportedImage(id: $0.id, data: $0.data) }
        var warnings = uiWarnings
        let imageRefs: [AgenticIntakeImageRef]

        do {
            imageRefs = try assetStore.saveImages(imported, for: eventID)
        } catch {
            imageRefs = []
            warnings.append("Some images could not be saved to the event.")
        }

        if !selectedImages.isEmpty && !currentProviderSupportsVision() {
            warnings.append("Current provider does not support image analysis. Images were saved but not used for AI inference.")
        }

        return AgenticIntakeRecord(
            rawText: rawText,
            images: imageRefs,
            source: source,
            providerMetadata: nil,
            warnings: orderedWarnings(warnings),
            createdAt: now,
            processingPhase: .analyzing,
            processingUpdatedAt: now,
            failureMessage: nil
        )
    }

    private func mergedIntake(
        _ current: AgenticIntakeRecord?,
        providerMetadata: AgenticProviderMetadata?,
        warnings: [String],
        processingPhase: AgenticIntakeProcessingPhase,
        failureMessage: String?
    ) -> AgenticIntakeRecord {
        let now = Date()
        if var current {
            current.providerMetadata = providerMetadata
            current.warnings = orderedWarnings(current.warnings + warnings)
            current.processingPhase = processingPhase
            current.processingUpdatedAt = now
            current.failureMessage = failureMessage
            return current
        }

        return AgenticIntakeRecord(
            rawText: "",
            images: [],
            source: .quickAdd,
            providerMetadata: providerMetadata,
            warnings: orderedWarnings(warnings),
            createdAt: now,
            processingPhase: processingPhase,
            processingUpdatedAt: now,
            failureMessage: failureMessage
        )
    }

    private func orderedWarnings(_ warnings: [String]) -> [String] {
        NSOrderedSet(array: warnings).array.compactMap { $0 as? String }
    }

    private func currentProviderSupportsVision() -> Bool {
        let provider = (UserDefaults.standard.string(forKey: AppSettingsKeys.agentProvider) ?? AppSettingsKeys.agentProviderDefault).lowercased()
        switch provider {
        case "deepseek":
            return false
        default:
            return true
        }
    }
}
