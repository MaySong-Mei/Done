import SwiftUI
import PhotosUI

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
    @Environment(\.dismiss) private var dismiss
    @StateObject private var templateStore = EventTypeTemplateStore()

    @State private var mode: Mode = .intake
    @State private var rawText: String = ""
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var selectedImages: [SelectedImageDraft] = []
    @State private var isAnalyzing = false
    @State private var errorMessage: String?
    @State private var transientWarnings: [String] = []

    private let maxImages = 5
    private let intakeService = AgenticCalendarIntakeService()
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
        .onChange(of: pickerItems.count) { _ in
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
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
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
            Button {
                Task { await createWithAI() }
            } label: {
                HStack {
                    if isAnalyzing {
                        ProgressView()
                            .progressViewStyle(.circular)
                    }
                    Text(isAnalyzing ? "Analyzing..." : "Create with AI")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canStartAI || isAnalyzing)

            if errorMessage != nil {
                Button("Retry") {
                    Task { await createWithAI() }
                }
                .buttonStyle(.bordered)
                .disabled(isAnalyzing)
            }

            Button("Use Classic Form") {
                mode = .classicForm
            }
            .buttonStyle(.bordered)
            .disabled(isAnalyzing)
        }
    }

    private var classicFormBody: some View {
        CalendarEventFormView(
            navigationTitle: "New Event",
            initialTitle: "",
            initialTypeTitle: templateStore.templates.first?.title ?? "Study",
            initialNote: rawText,
            initialLocation: "",
            initialStartTime: pendingCreate.timeRange.start,
            initialEndTime: pendingCreate.timeRange.end,
            agenticIntake: nil
        ) { form in
            var event = form.toEvent()
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
        let provider = (UserDefaults.standard.string(forKey: "agentProvider") ?? "claude").lowercased()
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
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
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

        do {
            let result = try await intakeService.generateAutofill(
                rawText: rawText,
                selectedImages: images,
                pendingCreate: pendingCreate,
                calendarContext: context,
                availableTypes: templateStore.templates.map(\.title)
            )

            var event = result.toFormData().toEvent()
            let providerMetadata = AgenticProviderMetadata(
                provider: result.providerName,
                model: result.providerModel,
                usedVision: result.usedVision
            )
            let intakeRecord = persistIntakeRecord(
                for: event.id,
                source: pendingCreate.source,
                providerMetadata: providerMetadata,
                warnings: result.warnings
            )
            event.agenticIntake = intakeRecord

            store.addCalendarEvent(event)
            onCreated(event)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
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
