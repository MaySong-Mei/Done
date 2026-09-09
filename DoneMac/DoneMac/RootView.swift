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
    @State private var composer: ComposerModel?
    @State private var composerShown = false
    @State private var accountShown = false
    @State private var observationShown = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .detailOnly

    var body: some View {
        Group {
            if runtime == nil {
                Text("Storage unavailable — running detached")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let surface, let todos, let drag {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    TodoDrawerView(todos: todos, onEditTodo: editEvent)
                        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
                } detail: {
                    CalendarCanvasView(surface: surface, drag: drag,
                                       onEditEvent: editEvent,
                                       onNameFreshCreation: nameFreshCreation)
                    .navigationTitle(surface.rangeTitle)
                    .toolbar { toolbar(surface) }
                }
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .sheet(isPresented: $composerShown) {
            if let composer {
                EventComposerView(composer: composer) { composerShown = false }
            }
        }
        .sheet(isPresented: $observationShown) {
            if let runtime {
                ObservationPanelView(bill: runtime.bill) { observationShown = false }
            }
        }
        .sheet(isPresented: $accountShown) {
            if let runtime {
                AccountView(auth: runtime.auth, sync: runtime.sync) { accountShown = false }
            }
        }
        .task {
            guard let runtime, surface == nil else { return }
            while !runtime.store.isLoaded {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if Task.isCancelled { return }
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
            runtime.onOcclusionChange = { [weak model] visible in
                model?.setVisible(visible, now: Date())
            }
            let todoModel = TodoSurfaceModel(store: runtime.store, bill: runtime.bill)
            todoModel.activate()
            todos = todoModel
            drag = DragController(store: runtime.store, calendar: runtime.calendar)
            composer = ComposerModel(store: runtime.store, calendar: runtime.calendar)
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didResignActiveNotification)) { _ in
            drag?.cancel()
        }
        .onDisappear {
            surface?.deactivate()
            surface = nil
            todos?.deactivate()
            todos = nil
            drag = nil
            composer = nil
        }
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
                composer?.openForCreate(day: surface.anchorDay, now: Date())
                composerShown = true
            } label: {
                Image(systemName: "plus")
            }
            .help("New event")

            if let runtime {
                SyncToolbarButton(auth: runtime.auth, sync: runtime.sync) {
                    accountShown = true
                }
            }

            Menu {
                Button("Account & Sync…") { accountShown = true }
                Button("Observation…") { observationShown = true }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: - Composer routing

    private func editEvent(_ id: UUID) {
        openComposer(id, namingFreshCreation: false)
    }

    private func nameFreshCreation(_ id: UUID) {
        openComposer(id, namingFreshCreation: true)
    }

    private func openComposer(_ id: UUID, namingFreshCreation: Bool) {
        guard let composer else { return }
        if composer.openForEdit(eventID: id, now: Date(), namingFreshCreation: namingFreshCreation) {
            composerShown = true
        }
    }
}

/// Sign-in / sync lives in the toolbar; AuthService is ObservableObject-era
/// so it needs @ObservedObject or a completed sign-in never updates the
/// button (round-5 review #2).
private struct SyncToolbarButton: View {
    @ObservedObject var auth: AuthService
    let sync: MacSyncEngine
    var showAccount: () -> Void

    var body: some View {
        if sync.isBusy {
            ProgressView().controlSize(.small)
        } else if auth.isSignedIn {
            Button { Task { await sync.syncNow(now: Date()) } } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
            }
            .help("Sync now")
        } else {
            Button("Sign in") { showAccount() }
        }
    }
}
