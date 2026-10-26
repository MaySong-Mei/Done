//
//  RootView.swift
//  DoneMac
//
//  The full-window calendar, styled after the iPhone app: a big vertical
//  day timeline that fills the window, a native macOS toolbar for range/
//  navigation/actions, and a collapsible todo sidebar (default collapsed).
//  Only the view layer differs from the phone — the store/projection/
//  canvasFrame/budget spine underneath is the same.
//

import SwiftUI

struct RootView: View {
    let runtime: MacAppRuntime?
    @State private var surface: CalendarSurfaceModel?
    @State private var todos: TodoSurfaceModel?
    @State private var drag: DragController?
    @State private var inspector: EventInspectorModel?
    /// The toolbar's "+" range (the phone's quick add); a drag-create's
    /// range lives on the drag controller, under its ghost.
    @State private var quickAddRange: Event.TimeRange?
    @AppStorage(AppSettingsKeys.calendarAgenticCreateEnabled) private var calendarAgenticCreateEnabled = true
    /// The window's height, so the create sheet never runs past it.
    @State private var windowHeight: CGFloat = 800
    @State private var accountShown = false
    @State private var observationShown = false
    @State private var typesShown = false
    @State private var isConfirmingErase = false
    /// This window's identity, for claiming the account-safety prompts and
    /// reporting edits in flight.
    @State private var windowID = UUID()
    /// What to do once the Account sheet has actually closed (Reset → erase
    /// confirmation, the recovery badge → the prompt). A presentation asked
    /// for while the sheet is still dismissing is dropped on macOS.
    @State private var afterAccountSheet: (() -> Void)?
    /// macOS: `.key` while this window has keyboard focus.
    @Environment(\.controlActiveState) private var controlActiveState
    /// The shared event-type catalog. Editing it reaches the inspector's type
    /// picker (this @ObservedObject store) AND the canvas: the surface
    /// subscribes to `EventTypeCatalog.changes` and rebuilds its color-baked
    /// frame (A2). One store mirrors the process-wide catalog.
    @StateObject private var typeStore = EventTypeTemplateStore()
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly

    var body: some View {
        Group {
            if runtime == nil {
                Text("Storage unavailable — running detached")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let surface, let todos, let drag {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    TodoDrawerView(todos: todos, onEditTodo: selectEvent)
                        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
                } detail: {
                    CalendarCanvasView(surface: surface, drag: drag,
                                       selectedID: inspector?.selectedID,
                                       onSelectBlock: { id, day in
                                           inspector?.select(id, occurrenceDate: day)
                                       },
                                       onOpenBlock: { id, day, intent in
                                           inspector?.open(id, occurrenceDate: day, intent: intent, now: Date())
                                       },
                                       // Context-menu quick actions are
                                       // id-addressed — they act on the
                                       // right-clicked block WITHOUT stealing
                                       // the pane's current selection (#1).
                                       onToggleDone: { id, day in
                                           inspector?.toggleDoneOccurrence(id: id, occurrenceDate: day, now: Date())
                                       },
                                       onDeleteBlock: { id, day in
                                           inspector?.delete(id: id, occurrenceDate: day, now: Date())
                                       })
                    .navigationTitle(surface.rangeTitle)
                    .toolbar { toolbar(surface) }
                    .inspector(isPresented: inspectorPresented) {
                        if let inspector {
                            EventInspectorView(model: inspector, typeStore: typeStore,
                                               journal: inspector.journalStore,
                                               agentRuntime: runtime?.agentRuntime) {
                                inspector.close()
                            }
                            .id(inspector.selectedID)
                            .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
                        }
                    }
                }
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { windowHeight = $0 }
        .overlay(alignment: .bottom) {
            if let runtime {
                StorageFaultBannerView(store: runtime.shared,
                                       eventTypeStore: runtime.agentRuntime.eventTypeTemplateStore,
                                       conversations: AgentConversationRepository.shared,
                                       occurrenceKeyMetadata: OccurrenceKeyMetadataStore.shared)
            }
        }
        .modifier(accountSafety)
        // The phone's create sheet (CreateCalendarEventView over the shared
        // CalendarEventFormView): nothing is added until its Done.
        .sheet(isPresented: createPresented) {
            if let runtime, let range = drag?.pendingCreate ?? quickAddRange {
                CreateCalendarEventView(
                    timeRange: range,
                    isTypeSuggestionEnabled: calendarAgenticCreateEnabled
                )
                .environmentObject(runtime.shared)
                .frame(width: 440, height: min(680, max(400, windowHeight - 24)))
            }
        }
        .sheet(isPresented: $typesShown) {
            TypeCatalogEditorView(store: typeStore) { typesShown = false }
        }
        .sheet(isPresented: $observationShown) {
            if let runtime {
                ObservationPanelView(bill: runtime.bill) { observationShown = false }
            }
        }
        .sheet(isPresented: $accountShown, onDismiss: {
            let next = afterAccountSheet
            afterAccountSheet = nil
            next?()
        }) {
            if let runtime {
                AccountView(auth: runtime.auth, sync: runtime.sync, status: runtime.syncStatus,
                            onResetAll: {
                                afterAccountSheet = { isConfirmingErase = true }
                                accountShown = false
                            },
                            onSwitchToThisAccount: {
                                let eraser = runtime.eraser
                                runtime.sync.switchToCurrentAccount {
                                    eraser.resetAllLocalData(keepingSession: true)
                                }
                            },
                            onShowRecovery: {
                                afterAccountSheet = { runtime.sync.inbound?.recovery.presentAgain() }
                                accountShown = false
                            }) { accountShown = false }
            }
        }
        .task {
            guard let runtime, surface == nil else { return }
            while !runtime.store.isLoaded {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if Task.isCancelled { return }
            buildModels(runtime)
        }
        .onChange(of: controlActiveState, initial: true) { _, state in
            guard state == .key, let runtime else { return }
            runtime.roles.safetyHostID = windowID
        }
        .onChange(of: isBusy, initial: true) { _, busy in
            runtime?.setWindow(windowID, busy: busy)
        }
        .onChange(of: runtime?.roles.dayFrameGeneration) { _, _ in
            // The runtime moved to a new zone while every window was idle.
            guard let runtime, surface != nil else { return }
            teardownModels()
            buildModels(runtime)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didResignActiveNotification)) { _ in
            drag?.cancel()
        }
        .onDisappear {
            teardownModels()
            runtime?.windowClosed(windowID)
        }
    }

    /// An edit is in flight in this window: a zone change must not rebuild
    /// the models under it (review round 2 (c): a rebuild lost the typed
    /// title, discarded a drop, and could leave a placeholder behind).
    private var isBusy: Bool {
        createPresented.wrappedValue || (drag?.isDragging ?? false) || (inspector?.isEditingText ?? false)
    }

    /// Surface models for this window, in the runtime's current day frame.
    private func buildModels(_ runtime: MacAppRuntime) {
            let now = Date()
            let model = CalendarSurfaceModel(
                store: runtime.store,
                clock: runtime.clock,
                calendar: runtime.calendar,
                bill: runtime.bill,
                anchor: now
            )
            model.activate(now: now)
            surface = model
            runtime.setOcclusionHandler(windowID) { [weak model] visible in
                model?.setVisible(visible, now: Date())
            }
            let todoModel = TodoSurfaceModel(store: runtime.store, bill: runtime.bill)
            todoModel.activate()
            todos = todoModel
            drag = DragController(store: runtime.store, calendar: runtime.calendar)
            let inspectorModel = EventInspectorModel(store: runtime.store, calendar: runtime.calendar)
            inspector = inspectorModel
            runtime.setDraftFlusher(windowID) { [weak inspectorModel] in
                inspectorModel?.flushDrafts(now: Date())
            }
    }

    private func teardownModels() {
        surface?.deactivate()
        surface = nil
        todos?.deactivate()
        todos = nil
        drag = nil
        inspector = nil
    }

    /// Account-safety prompts over the whole window (gh#257). Detached
    /// runtime: nothing to guard.
    private var accountSafety: OptionalModifier<AccountSafetyModifier> {
        // Runtime presence never changes for a window's lifetime, so this is
        // the only branch; the host role is a parameter (round 3 #1).
        guard let runtime else { return OptionalModifier(nil) }
        return OptionalModifier(AccountSafetyModifier(
            sync: runtime.sync, auth: runtime.auth,
            erase: { runtime.eraser.resetAllLocalData(keepingSession: false) },
            isConfirmingErase: $isConfirmingErase,
            isHost: runtime.roles.safetyHostID == windowID))
    }

    /// The inspector's open state as a Bool binding for `.inspector`; closing
    /// via the chrome clears the selection so the canvas ring drops too.
    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: { inspector?.isOpen ?? false },
            set: { if !$0 { inspector?.close() } }
        )
    }

    // MARK: - Toolbar (native macOS)

    @ToolbarContentBuilder
    private func toolbar(_ surface: CalendarSurfaceModel) -> some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { surface.stepWindow(-1, now: Date()) } label: {
                Image(systemName: "chevron.left")
            }
            .help("Previous")
            Button("Today") { surface.goToToday(now: Date()) }
            Button { surface.stepWindow(1, now: Date()) } label: {
                Image(systemName: "chevron.right")
            }
            .help("Next")
        }
        ToolbarItem(placement: .principal) {
            Picker("View", selection: Binding(
                get: { surface.rangeMode },
                set: { surface.setRangeMode($0, now: Date()) }
            )) {
                ForEach(CalendarRangeMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                quickAddRange = Self.quickAddTimeRange(day: surface.anchorDay, now: Date(),
                                                       calendar: runtime?.calendar ?? .current)
            } label: {
                Image(systemName: "plus")
            }
            .help("New event")

            if let runtime {
                SyncToolbarButton(auth: runtime.auth, sync: runtime.sync, status: runtime.syncStatus) {
                    accountShown = true
                }
            }

            Menu {
                Button("Event Types…") { typesShown = true }
                Button("Account & Sync…") { accountShown = true }
                Button("Observation…") { observationShown = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: - Selection / composer routing

    /// A block click opens the inspector hub (the phone's tap→detail model).
    private func selectEvent(_ id: UUID) {
        inspector?.select(id)
    }

    /// The create sheet is up for a drag-create's ghost or the toolbar's
    /// "+"; closing it (Done, Cancel, Esc) drops both.
    private var createPresented: Binding<Bool> {
        Binding(
            get: { drag?.pendingCreate != nil || quickAddRange != nil },
            set: { shown in
                guard !shown else { return }
                drag?.finishPendingCreate()
                quickAddRange = nil
            }
        )
    }

    /// The phone's `defaultQuickAddTimeRange`: the shown day at the current
    /// clock time rounded up to the quarter hour, one hour long.
    static func quickAddTimeRange(day: DayKey, now: Date, calendar: Calendar) -> Event.TimeRange {
        let dayStart = day.startOfDay(calendar: calendar) ?? calendar.startOfDay(for: now)
        let timeSource = calendar.isDate(dayStart, inSameDayAs: now)
            ? now
            : calendar.date(bySettingHour: calendar.component(.hour, from: now),
                            minute: calendar.component(.minute, from: now),
                            second: 0, of: dayStart) ?? dayStart
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: timeSource)
        let minute = components.minute ?? 0
        let remainder = minute % 15
        if remainder != 0 {
            components.minute = minute + (15 - remainder)
        }
        components.second = 0
        let start = calendar.date(from: components) ?? timeSource
        return Event.TimeRange(start: start, end: start.addingTimeInterval(3600))
    }
}

/// Sign-in / sync lives in the toolbar; AuthService is ObservableObject-era
/// so it needs @ObservedObject or a completed sign-in never updates the
/// button (round-5 review #2).
private struct SyncToolbarButton: View {
    @ObservedObject var auth: AuthService
    let sync: SupabaseSyncService
    @ObservedObject var status: SyncStatusReporter
    var showAccount: () -> Void

    var body: some View {
        if status.structured.isActive {
            ProgressView().controlSize(.small)
        } else if auth.isSignedIn {
            Button { sync.inbound?.requestPull(reason: "mac-toolbar") } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .help("Sync now")
        } else {
            Button("Sign in") { showAccount() }
        }
    }
}

/// Applies `inner` when present — the detached-runtime branch has no engine.
private struct OptionalModifier<Inner: ViewModifier>: ViewModifier {
    let inner: Inner?
    init(_ inner: Inner?) { self.inner = inner }
    func body(content: Content) -> some View {
        if let inner { content.modifier(inner) } else { content }
    }
}
