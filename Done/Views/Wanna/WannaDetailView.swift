//
//  WannaDetailView.swift
//  Done
//
//  Detail view for a wanna item with header toolbar for attributes.
//

import SwiftUI

struct WannaDetailView: View {
    let eventID: UUID
    @EnvironmentObject private var store: EventStore
    @Environment(\.dismiss) private var dismiss
    @State private var isEditingTitle = false
    @State private var isEditingNote = false
    @State private var draftTitle = ""
    @State private var draftNote = ""
    @State private var showDeadlinePicker = false
    @State private var draftDeadline = Date()
    @State private var showTagSheet = false
    @State private var newTagDraft = ""
    @FocusState private var noteFocused: Bool
    @FocusState private var newTagFieldFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    private var event: Event? {
        store.events.first { $0.id == eventID }
    }

    private var eventColor: Color {
        guard let event else { return .secondary }
        return EventTypeTemplateStore.color(for: event.type)
    }

    var body: some View {
        ScrollView {
            if let event {
                VStack(alignment: .leading, spacing: 20) {
                    titleSection(event)
                    chipBar(event)
                    noteSection(event)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            // iOS sometimes posts keyboardWillHide DURING the background
            // transition (scenePhase already off .active by then). That
            // implicit hide must take the scene-departure path — the plain
            // one would run commitEditNote's delete-on-empty branch and
            // destroy a note whose buffer the user had merely emptied
            // mid-rewrite. A deliberate foreground tap-away keeps the
            // existing full-dismiss semantics.
            if scenePhase == .active {
                dismissEditing()
            } else {
                flushEditsForSceneDeparture()
            }
        }
        // keyboardWillHide does not fire reliably on backgrounding and never
        // on process death — a typed-but-still-focused title/note edit would
        // die with the process. All commits no-op when repeated, so double
        // firing with the handler above is safe. `.background` only:
        // committing on .inactive flaps (notification shade, Face ID) would
        // tear down the editor and commit fragments mid-thought.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                flushEditsForSceneDeparture()
            }
        }
        .background(Color.clear)
        .background { WannaInteractivePopBridge() }
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top) {
            VStack(spacing: 8) {
                detailHeader
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $showDeadlinePicker) {
            deadlineSheet
        }
        .sheet(isPresented: $showTagSheet) {
            tagSheet
        }
    }

    // MARK: - Header

    private var detailHeader: some View {
        SwiftUI.GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                // Left capsule: back + title
                Button {
                    dismiss()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                        Text(event?.title ?? L(.wannaFallback))
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .contentShape(Capsule())
                    .background(Color.black.opacity(0.001), in: Capsule())
                    .glassEffect(.regular.interactive(), in: Capsule())
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                // Right capsule: exposed add button + "..." overflow
                if let event {
                    HStack(spacing: 0) {
                        // Exposed: add attributes
                        addAttributeMenu(event)
                        headerDivider

                        // "..." overflow menu
                        Menu {
                            if event.linkedCalendarEventId != nil {
                                Button { store.recallWannaFromCalendar(event) } label: {
                                    Label(L(.recallFromCalendar), systemImage: "calendar.badge.minus")
                                }
                            } else {
                                Button { store.pushWannaToCalendar(event) } label: {
                                    Label(L(.pushToCalendar), systemImage: "calendar.badge.plus")
                                }
                            }

                            Button {
                                withAnimation { store.completeWanna(event); dismiss() }
                            } label: {
                                Label(L(.completeLabel), systemImage: "checkmark")
                            }

                            Divider()

                            Button(role: .destructive) {
                                store.markArchived(event); dismiss()
                            } label: {
                                Label(L(.delete), systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(width: 36, height: 40)
                                .contentShape(Rectangle())
                        }
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(height: 40)
                    .contentShape(Capsule())
                    .background(Color.black.opacity(0.001), in: Capsule())
                    .glassEffect(.regular.interactive(), in: Capsule())
                }
            }
        }
    }

    private var headerDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.14))
            .frame(width: 1, height: 16)
    }

    // MARK: - Add Attribute Menu

    @ViewBuilder
    private func addAttributeMenu(_ event: Event) -> some View {
        let types = ["Wanna", "Study", "Work", "Exercise", "Sleep"]

        Menu {
            // Type sub-menu
            Menu {
                ForEach(types, id: \.self) { t in
                    Button {
                        updateField { $0.type = t }
                    } label: {
                        if event.type == t {
                            Label(t, systemImage: "checkmark")
                        } else {
                            Text(t)
                        }
                    }
                }
            } label: {
                Label("Type: \(event.type.isEmpty ? "–" : event.type)", systemImage: "paintpalette")
            }

            // Deadline
            Button {
                draftDeadline = event.deadline ?? Date()
                showDeadlinePicker = true
            } label: {
                if let dl = event.deadline {
                    Label("Deadline: \(deadlineText(dl))", systemImage: "clock")
                } else {
                    Label(L(.addDeadline), systemImage: "clock")
                }
            }

            // Priority
            Menu {
                ForEach(0...3, id: \.self) { level in
                    Button {
                        updateField { $0.priority = level }
                    } label: {
                        let label = level == 0 ? "None" : String(repeating: "!", count: level)
                        if event.priority == level {
                            Label(label, systemImage: "checkmark")
                        } else {
                            Text(label)
                        }
                    }
                }
            } label: {
                Label("Priority: \(event.priority == 0 ? "–" : String(repeating: "!", count: event.priority))", systemImage: "flag")
            }

            // Tags
            Button {
                newTagDraft = ""
                showTagSheet = true
            } label: {
                Label(
                    event.tags.isEmpty ? L(.addTag) : "\(L(.tags)): \(event.tags.count)",
                    systemImage: "tag"
                )
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                Text(L(.add))
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
    }

    // MARK: - Title

    @ViewBuilder
    private func titleSection(_ event: Event) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(eventColor)
                    .frame(width: 5, height: 28)

                if isEditingTitle {
                    TextField(L(.title), text: $draftTitle)
                        .font(.system(size: 22, weight: .bold))
                        .onSubmit { commitTitle() }
                        .onAppear { draftTitle = event.title }
                } else {
                    Text(event.title)
                        .font(.system(size: 22, weight: .bold))
                        .onTapGesture {
                            draftTitle = event.title
                            isEditingTitle = true
                        }
                }
            }

            Text(createdAtText(event.createdAt))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.leading, 15)
        }
    }

    private func createdAtText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a"
        return formatter.string(from: date)
    }

    private func commitTitle() {
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != event?.title else {
            isEditingTitle = false
            return
        }
        updateField { $0.title = trimmed }
        isEditingTitle = false
    }

    // MARK: - Chip Bar

    @ViewBuilder
    private func chipBar(_ event: Event) -> some View {
        let hasChips = !event.type.isEmpty || event.deadline != nil || event.priority > 0 || event.linkedCalendarEventId != nil || !event.tags.isEmpty

        if hasChips {
            FlowLayout(spacing: 6) {
                if !event.type.isEmpty {
                    chip(event.type, color: eventColor)
                }
                if let deadline = event.deadline {
                    chip(deadlineText(deadline), color: deadline < Date() ? .red : .orange, icon: "clock")
                }
                if event.priority > 0 {
                    chip(String(repeating: "!", count: min(event.priority, 3)), color: .red, icon: "flag.fill")
                }
                if event.linkedCalendarEventId != nil {
                    chip("Scheduled", color: eventColor, icon: "calendar")
                }
                ForEach(event.tags, id: \.self) { tag in
                    Button {
                        newTagDraft = ""
                        showTagSheet = true
                    } label: {
                        chip("#\(tag)", color: eventColor.opacity(0.85))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func chip(_ text: String, color: Color, icon: String? = nil) -> some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.1))
        .clipShape(Capsule())
    }

    private func deadlineText(_ deadline: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: deadline)
    }

    // MARK: - Note

    @State private var editingNoteID: UUID?

    @ViewBuilder
    private func noteSection(_ event: Event) -> some View {
        let notes = event.wannaNotes ?? []

        VStack(alignment: .leading, spacing: 12) {
            ForEach(notes) { note in
                let isEditing = editingNoteID == note.id
                noteBullet(note: note, isEditing: isEditing)
            }

            // New note input or prompt
            if isEditingNote && editingNoteID == nil {
                noteBulletEditor()
            } else if editingNoteID == nil {
                Text(L(.tapToAddNote))
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
                    .onTapGesture {
                        draftNote = ""
                        isEditingNote = true
                    }
            }
        }
    }

    @ViewBuilder
    private func noteBullet(note: Event.WannaNote, isEditing: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(eventColor)
                .frame(width: 6, height: 6)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 3) {
                if isEditing {
                    TextEditor(text: $draftNote)
                        .font(.system(size: 15))
                        .frame(minHeight: 40)
                        .scrollContentBackground(.hidden)
                        .focused($noteFocused)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                noteFocused = true
                            }
                        }
                } else {
                    Text(note.text)
                        .font(.system(size: 15))
                        .foregroundStyle(.primary)
                }

                HStack(spacing: 6) {
                    Text(createdAtText(note.createdAt))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.quaternary)

                    Spacer()

                    if isEditing {
                        Button { commitEditNote(noteID: note.id) } label: {
                            Text(L(.done))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(eventColor)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .scaleEffect(isEditing ? 1.03 : 1, anchor: .leading)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isEditing)
        .contentShape(Rectangle())
        .onTapGesture {
            if !isEditing {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    draftNote = note.text
                    editingNoteID = note.id
                }
            }
        }
    }

    @ViewBuilder
    private func noteBulletEditor() -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(eventColor.opacity(0.4))
                .frame(width: 6, height: 6)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 3) {
                TextEditor(text: $draftNote)
                    .font(.system(size: 15))
                    .frame(minHeight: 40)
                    .scrollContentBackground(.hidden)
                    .focused($noteFocused)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            noteFocused = true
                        }
                    }

                HStack {
                    Spacer()
                    Button { commitNewNote() } label: {
                        Text(L(.done))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(eventColor)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .transition(.opacity.combined(with: .offset(y: -4)))
    }

    /// Scene-departure variant of `dismissEditing`: deletion must never come
    /// from an implicit background dismissal. An emptied buffer mid-rewrite
    /// of an existing note skips the note commit (the original survives;
    /// worst case the rewrite dies with the process) — while a title edit
    /// running in parallel still commits.
    private func flushEditsForSceneDeparture() {
        if editingNoteID != nil,
           draftNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if isEditingTitle {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    commitTitle()
                }
            }
            return
        }
        dismissEditing()
    }

    private func dismissEditing() {
        guard isEditingNote || editingNoteID != nil || isEditingTitle else { return }
        noteFocused = false
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            if let noteID = editingNoteID {
                commitEditNote(noteID: noteID)
            } else if isEditingNote {
                commitNewNote()
            }
            if isEditingTitle {
                commitTitle()
            }
        }
    }

    private func commitNewNote() {
        let trimmed = draftNote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                isEditingNote = false
            }
            return
        }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            updateField {
                var notes = $0.wannaNotes ?? []
                notes.append(Event.WannaNote(text: trimmed))
                $0.wannaNotes = notes
            }
            isEditingNote = false
            draftNote = ""
        }
    }

    private func commitEditNote(noteID: UUID) {
        let trimmed = draftNote.trimmingCharacters(in: .whitespacesAndNewlines)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            if trimmed.isEmpty {
                // Delete empty note
                updateField {
                    var notes = $0.wannaNotes ?? []
                    notes.removeAll { $0.id == noteID }
                    $0.wannaNotes = notes.isEmpty ? nil : notes
                }
            } else {
                updateField {
                    guard var notes = $0.wannaNotes,
                          let idx = notes.firstIndex(where: { $0.id == noteID }) else { return }
                    notes[idx].text = trimmed
                    $0.wannaNotes = notes
                }
            }
            editingNoteID = nil
            draftNote = ""
        }
    }

    // MARK: - Deadline Sheet

    private var deadlineSheet: some View {
        NavigationStack {
            VStack(spacing: 16) {
                DatePicker("Deadline", selection: $draftDeadline, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.graphical)

                if event?.deadline != nil {
                    Button(L(.removeDeadline), role: .destructive) {
                        updateField { $0.deadline = nil }
                        showDeadlinePicker = false
                    }
                }
            }
            .padding()
            .navigationTitle(L(.deadline))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L(.cancel)) { showDeadlinePicker = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L(.setLabel)) {
                        updateField { $0.deadline = draftDeadline }
                        showDeadlinePicker = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    // MARK: - Tag Sheet

    private var tagSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let event, !event.tags.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(event.tags, id: \.self) { tag in
                                Button {
                                    updateField { $0.tags.removeAll { $0 == tag } }
                                } label: {
                                    HStack(spacing: 4) {
                                        Text("#\(tag)")
                                            .font(.system(size: 13, weight: .medium))
                                        Image(systemName: "xmark")
                                            .font(.system(size: 10, weight: .semibold))
                                    }
                                    .foregroundStyle(eventColor)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(eventColor.opacity(0.15), in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "tag")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                        TextField(L(.enterTag), text: $newTagDraft)
                            .focused($newTagFieldFocused)
                            .submitLabel(.done)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit { commitNewTag() }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .padding(16)
            }
            .navigationTitle(L(.tags))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L(.done)) {
                        commitNewTag()
                        showTagSheet = false
                    }
                }
            }
            .onAppear { newTagFieldFocused = true }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func commitNewTag() {
        let trimmed = newTagDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard !trimmed.isEmpty else { return }
        guard let event, !event.tags.contains(trimmed) else {
            newTagDraft = ""
            return
        }
        updateField { $0.tags.append(trimmed) }
        newTagDraft = ""
    }

    // MARK: - Helpers

    private func updateField(_ mutate: (inout Event) -> Void) {
        guard var updated = event else { return }
        mutate(&updated)
        store.update(updated)
    }
}

// MARK: - Interactive Pop Bridge

private struct WannaInteractivePopBridge: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ vc: Controller, context: Context) {
        vc.refreshInteractivePopGestureIfNeeded()
    }

    final class Controller: UIViewController {
        override func loadView() {
            let v = UIView()
            v.backgroundColor = .clear
            v.isUserInteractionEnabled = false
            self.view = v
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            refreshInteractivePopGestureIfNeeded()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            refreshInteractivePopGestureIfNeeded()
        }

        func refreshInteractivePopGestureIfNeeded() {
            guard let nav = navigationController,
                  let gesture = nav.interactivePopGestureRecognizer else { return }
            gesture.isEnabled = nav.viewControllers.count > 1
            gesture.delegate = nil
        }
    }
}
