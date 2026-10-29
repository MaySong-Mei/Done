//
//  InspectorReflectionSection.swift
//  DoneMac
//
//  The phone detail's Reflection page in the Mac inspector: completion,
//  effort, signals (emotion / behavior), the reflection note and images.
//  Same strings and the same writes as the phone (InspectorReflectionModel);
//  the effort dots are the inspector's existing control, now writing the
//  record the phone reads.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct InspectorReflectionSection: View {
    let event: Event
    @Bindable var reflection: InspectorReflectionModel
    /// Observed so a record change from anywhere (sync, the effort dots)
    /// redraws the selections.
    @ObservedObject var journal: EventStore
    let effort: AnyView
    /// Replaces the event's intake images (customizing a series occurrence,
    /// as the phone's editOccurrence does).
    let setImages: ([AgenticIntakeImageRef]) -> Void
    var onEditingText: (Bool) -> Void = { _ in }

    @State private var isImportingImages = false
    @FocusState private var noteFocused: Bool

    private static let maxImages = 5
    private let assets = AgenticIntakeAssetStore()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            completion
            card(L(.effort)) { effort }
            signals
            card(L(.note)) {
                TextEditor(text: $reflection.noteText)
                    .font(.callout)
                    .focused($noteFocused)
                    .frame(minHeight: 80, maxHeight: 200)
                    .scrollContentBackground(.hidden)
                    .padding(4)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            }
            images
        }
        .onChange(of: noteFocused) { _, focused in
            onEditingText(focused)
            if !focused { reflection.flush() }
        }
        .onDisappear {
            reflection.flush()
            onEditingText(false)
        }
        .fileImporter(isPresented: $isImportingImages, allowedContentTypes: [.image],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            addImages(urls)
        }
    }

    // MARK: - Completion

    private var completion: some View {
        card(L(.completion)) {
            HStack(spacing: 8) {
                ForEach(EventLogCompletionStatus.allCases) { status in
                    let selected = reflection.completionStatus == status
                    Button { reflection.setCompletion(status) } label: {
                        Text(status.title)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selected ? Color.primary.opacity(0.14) : Color.secondary.opacity(0.08),
                                        in: Capsule())
                            .foregroundStyle(selected ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Signals

    private var signals: some View {
        card("Signals") {
            VStack(alignment: .leading, spacing: 12) {
                tagPicker(L(.emotion), axis: .emotions,
                          tags: CalendarEmotionTag.allCases.map { ($0.rawValue, $0.title) },
                          selection: reflection.emotions)
                tagPicker(L(.behaviorLabel), axis: .behaviors,
                          tags: CalendarBehaviorTag.allCases.map { ($0.rawValue, $0.title) },
                          selection: reflection.behaviors)
            }
        }
    }

    /// The phone's quickTagPicker: the button reports intent ("make this tag
    /// ON/OFF" from what was rendered); the store re-reads at tap time.
    private func tagPicker(_ title: String, axis: CalendarQuickTagAxis,
                           tags: [(id: String, title: String)], selection: Set<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(tags, id: \.id) { tag in
                    let selected = selection.contains(tag.id)
                    Button { reflection.toggle(axis, tagID: tag.id, targetSelected: !selected) } label: {
                        Text(tag.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1),
                                        in: Capsule())
                            .foregroundStyle(selected ? Color.accentColor : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Images

    private var currentImages: [AgenticIntakeImageRef] { event.agenticIntake?.images ?? [] }

    private var images: some View {
        card(L(.images)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Spacer()
                    Button { isImportingImages = true } label: { Image(systemName: "plus.circle") }
                        .buttonStyle(.borderless)
                        .disabled(currentImages.count >= Self.maxImages)
                        .help("Add images")
                }
                if !currentImages.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(currentImages) { ref in
                                ZStack(alignment: .topTrailing) {
                                    Group {
                                        if let image = NSImage(contentsOf: assets.absoluteURL(for: ref)) {
                                            Image(nsImage: image).resizable().scaledToFill()
                                        } else {
                                            Color.secondary.opacity(0.15)
                                        }
                                    }
                                    .frame(width: 72, height: 72)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .onTapGesture { NSWorkspace.shared.open(assets.absoluteURL(for: ref)) }
                                    Button {
                                        setImages(currentImages.filter { $0.id != ref.id })
                                    } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.5))
                                    }
                                    .buttonStyle(.plain)
                                    .offset(x: 4, y: -4)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
        }
    }

    private func addImages(_ urls: [URL]) {
        var imported: [AgenticIntakeAssetStore.ImportedImage] = []
        for url in urls {
            guard currentImages.count + imported.count < Self.maxImages else { break }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) {
                imported.append(.init(data: data))
            }
        }
        guard !imported.isEmpty,
              let refs = try? assets.saveImages(imported, for: event.id) else { return }
        setImages(currentImages + refs)
    }

    // MARK: - Card

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }
}
