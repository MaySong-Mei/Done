import SwiftUI
import PhotosUI
import Combine

struct CalendarAgenticCreateView: View {
    private enum Mode {
        case intake
        case classicForm
    }

    private struct SelectedImageDraft: Identifiable {
        let id: UUID
        let data: Data
        let preview: UIImage
    }

    let pendingCreate: PendingEventCreation
    let onCreated: (Event) -> Void

    @EnvironmentObject private var store: EventStore
    @EnvironmentObject private var agentRuntime: AgentRuntime
    @EnvironmentObject private var agenticCreateCoordinator: CalendarAgenticCreateCoordinator
    @Environment(\.dismiss) private var dismiss
    @AppStorage(AppSettingsKeys.calendarAgenticCreateEnabled) private var calendarAgenticCreateEnabled = true
    @StateObject private var templateStore = EventTypeTemplateStore()

    @State private var mode: Mode = .intake
    @State private var rawText: String = ""
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var selectedImages: [SelectedImageDraft] = []
    @State private var isAnalyzing = false
    @State private var errorMessage: String?
    @State private var transientWarnings: [String] = []

    private let maxImages = 5
    private let assetStore = AgenticIntakeAssetStore()

    var body: some View {
        Group {
            switch mode {
            case .intake:
                intakeBody
            case .classicForm:
                classicFormBody
            }
        }
        .onChange(of: pickerItems.count) {
            let items = pickerItems
            guard !items.isEmpty else { return }
            Task { await loadPickedImages(items) }
        }
    }

    private var intakeBody: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    textInputCard
                    imagePickerCard
                    contextHintCard
                    if let errorMessage {
                        errorCard(errorMessage)
                    }
                    if !transientWarnings.isEmpty {
                        warningCard(transientWarnings)
                    }
                    actionButtons
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 24)
            }
            .navigationTitle("Agentic Create")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isAnalyzing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await createWithAI() }
                    }
                    .disabled(!canStartAI || isAnalyzing)
                }
            }
        }
    }

    private var textInputCard: some View {
        intakeCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Describe what happened or what you want to schedule")
                    .font(.headline)
                TextEditor(text: $rawText)
                    .frame(minHeight: 110)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                Text("You can use the keyboard mic for system dictation.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var imagePickerCard: some View {
        intakeCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Images")
                        .font(.headline)
                    Spacer()
                    Text("\(selectedImages.count)/\(maxImages)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                PhotosPicker(
                    selection: $pickerItems,
                    maxSelectionCount: max(0, maxImages - selectedImages.count),
                    matching: .images
                ) {
                    Label("Add Photos", systemImage: "photo.on.rectangle.angled")
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Capsule())
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                        .glassEffect(.regular.interactive(), in: Capsule())
                }
                .disabled(isAnalyzing || selectedImages.count >= maxImages)

                if !selectedImages.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(selectedImages) { item in
                                ZStack(alignment: .topTrailing) {
                                    Image(uiImage: item.preview)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 84, height: 84)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))

                                    Button {
                                        removeImage(id: item.id)
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.white, .black.opacity(0.65))
                                    }
                                    .offset(x: 4, y: -4)
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                if hasImageVisionFallbackWarning {
                    Text("Current provider may not support image analysis. Images will still be saved to the event, but AI may use text only.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var contextHintCard: some View {
        intakeCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("How AI uses this")
                    .font(.headline)
                Text(agenticModeHintText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Your selected provider receives the text and compatible images to infer title/type/duration/time.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button("Use Classic Form") {
                mode = .classicForm
            }
            .buttonStyle(.bordered)
            .disabled(isAnalyzing)
        }
    }

    private var classicFormBody: some View {
        CalendarEventFormView(
            navigationTitle: L(.newEvent),
            initialTitle: "",
            initialTypeTitle: templateStore.templates.first?.title ?? "Study",
            initialNote: rawText,
            initialLocation: "",
            initialStartTime: pendingCreate.timeRange.start,
            initialEndTime: pendingCreate.timeRange.end,
            agenticIntake: nil,
            allowsAutomaticTypeSelection: calendarAgenticCreateEnabled
        ) { form in
            var event = form.toEvent()
            event = EventLogTemplateAdvisor().applySuggestion(to: event)
            let intake = persistIntakeRecord(
                for: event.id,
                source: .classicFallback,
                providerMetadata: nil,
                warnings: transientWarnings
            )
            event.agenticIntake = intake
            store.addCalendarEvent(event)
            onCreated(event)
        }
    }

    private var canStartAI: Bool {
        let hasText = !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasImages = !selectedImages.isEmpty
        if hasImages && !hasText && hasImageVisionFallbackWarning {
            return false
        }
        return hasText || hasImages
    }

    private var hasImageVisionFallbackWarning: Bool {
        guard !selectedImages.isEmpty else { return false }
        let provider = (UserDefaults.standard.string(forKey: AppSettingsKeys.agentProvider) ?? AppSettingsKeys.agentProviderDefault).lowercased()
        return provider == "deepseek"
    }

    private var agenticModeHintText: String {
        switch pendingCreate.source {
        case .dragCreate:
            return "Drag-create mode: AI fills title/type/details, but the dragged time range is kept exactly."
        case .quickAdd:
            return "Quick-add mode: AI can infer date/time (including nearby days), duration, title, and type."
        case .classicFallback:
            return "Classic fallback mode."
        }
    }

    @ViewBuilder
    private func intakeCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        GlassCardView(cornerRadius: 16, contentPadding: 14) {
            content()
        }
    }

    private func errorCard(_ message: String) -> some View {
        intakeCard {
            VStack(alignment: .leading, spacing: 6) {
                Label("AI Create Failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.headline)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func warningCard(_ warnings: [String]) -> some View {
        intakeCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("Warnings")
                    .font(.headline)
                ForEach(Array(warnings.enumerated()), id: \.offset) { entry in
                    Text("• \(entry.element)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func removeImage(id: UUID) {
        selectedImages.removeAll { $0.id == id }
        transientWarnings.removeAll { $0.contains("image") }
    }

    @MainActor
    private func loadPickedImages(_ items: [PhotosPickerItem]) async {
        defer { pickerItems = [] }
        guard selectedImages.count < maxImages else { return }

        for item in items {
            if selectedImages.count >= maxImages { break }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let uiImage = UIImage(data: data) else {
                continue
            }
            selectedImages.append(SelectedImageDraft(id: UUID(), data: data, preview: uiImage))
        }
    }

    @MainActor
    private func createWithAI() async {
        errorMessage = nil
        transientWarnings = transientWarnings.filter { !$0.contains("image analysis") }

        let hasText = !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !hasText && !selectedImages.isEmpty && hasImageVisionFallbackWarning {
            errorMessage = "The current provider cannot analyze images. Please add some text or switch provider."
            return
        }

        isAnalyzing = true
        defer { isAnalyzing = false }

        let images = selectedImages.map { AgenticInputImage(id: $0.id, data: $0.data) }
        let context = AgenticCalendarContext(
            visibleDate: pendingCreate.anchorVisibleDate,
            nearbyEventsSummary: buildNearbyEventsSummary()
        )

        let placeholder = agenticCreateCoordinator.submitOptimisticCreate(
            rawText: rawText,
            selectedImages: images,
            pendingCreate: pendingCreate,
            calendarContext: context,
            availableTypes: templateStore.templates.map(\.title),
            uiWarnings: transientWarnings,
            agentRuntime: agentRuntime,
            store: store
        )
        onCreated(placeholder)
        dismiss()
    }

    private func persistIntakeRecord(
        for eventID: UUID,
        source: AgenticCreateSource,
        providerMetadata: AgenticProviderMetadata?,
        warnings: [String]
    ) -> AgenticIntakeRecord? {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let imported = selectedImages.map { AgenticIntakeAssetStore.ImportedImage(id: $0.id, data: $0.data) }
        let imageRefs = (try? assetStore.saveImages(imported, for: eventID)) ?? []

        guard !trimmed.isEmpty || !imageRefs.isEmpty || !warnings.isEmpty || providerMetadata != nil else {
            return nil
        }

        return AgenticIntakeRecord(
            rawText: trimmed,
            images: imageRefs,
            source: source,
            providerMetadata: providerMetadata,
            warnings: warnings
        )
    }

    private func buildNearbyEventsSummary() -> String {
        let calendar = Calendar.current
        let anchorDay = calendar.startOfDay(for: pendingCreate.anchorVisibleDate)
        let start = calendar.date(byAdding: .day, value: -1, to: anchorDay) ?? anchorDay
        let end = calendar.date(byAdding: .day, value: 2, to: anchorDay) ?? anchorDay

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short

        let lines = store.calendarEvents
            .compactMap { event -> String? in
                guard let range = event.effectiveTimeRanges.first else { return nil }
                guard range.end > start && range.start < end else { return nil }
                return "- \(event.title): \(formatter.string(from: range.start)) → \(formatter.string(from: range.end)) [\(event.type)]"
            }
            .prefix(12)

        return lines.joined(separator: "\n")
    }
}

enum CalendarAgenticBannerState: Equatable, Identifiable {
    case analyzing(eventID: UUID)
    case moved(eventID: UUID, destination: Date)
    case failed(eventID: UUID, message: String)

    var id: String {
        switch self {
        case .analyzing(let eventID):
            return "analyzing-\(eventID.uuidString)"
        case .moved(let eventID, let destination):
            return "moved-\(eventID.uuidString)-\(destination.timeIntervalSince1970)"
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
        guard let current = store.calendarEvents.first(where: { $0.id == eventID }) else {
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
        if let current = store.calendarEvents.first(where: { $0.id == eventID }) {
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
            if let current = store.calendarEvents.first(where: { $0.id == eventID }),
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
