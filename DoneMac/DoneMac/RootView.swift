//
//  RootView.swift
//  DoneMac
//
//  Phase 3 shell: the read-only calendar canvas over the truth layer.
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

    var body: some View {
        Group {
            if runtime == nil {
                Text("Storage unavailable — running detached")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let surface, let todos, let drag {
                HSplitView {
                    TodoDrawerView(todos: todos, onEditTodo: editEvent)
                    VStack(spacing: 0) {
                        controls(surface)
                        CalendarCanvasView(surface: surface, drag: drag,
                                           onEditEvent: editEvent,
                                           onNameFreshCreation: nameFreshCreation)
                    }
                }
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 920, minHeight: 520)
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

    private func controls(_ surface: CalendarSurfaceModel) -> some View {
        HStack {
            Button("◀︎ Week") { surface.shift(byDays: -7, now: Date()) }
            Button("Today") {
                let now = Date()
                surface.shift(byDays: daysToToday(surface, now: now), now: now)
            }
            Button("Week ▶︎") { surface.shift(byDays: 7, now: Date()) }
            Button("New…") {
                guard let composer else { return }
                composer.openForCreate(day: surface.anchorDay, now: Date())
                composerShown = true
            }
            Spacer()
            if let runtime {
                SyncControls(auth: runtime.auth, sync: runtime.sync) {
                    accountShown = true
                }
                Button("Observation…") { observationShown = true }
                    .help("Live work-bill counters and tripwires")
            }
            Text("\(surface.frame.days.reduce(0) { $0 + $1.blocks.count }) blocks")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(8)
    }

    private func daysToToday(_ surface: CalendarSurfaceModel, now: Date) -> Int {
        guard let runtime else { return 0 }
        let calendar = runtime.calendar
        guard let anchorStart = surface.anchorDay.startOfDay(calendar: calendar) else { return 0 }
        let todayStart = calendar.startOfDay(for: now)
        return calendar.dateComponents([.day], from: anchorStart, to: todayStart).day ?? 0
    }
}

/// Auth-observing toolbar island: AuthService is ObservableObject-era, so
/// these reads need @ObservedObject or a sign-in never updates the button
/// (round-5 review #2).
private struct SyncControls: View {
    @ObservedObject var auth: AuthService
    let sync: MacSyncEngine
    var showAccount: () -> Void

    var body: some View {
        if sync.isBusy {
            ProgressView().controlSize(.small)
        }
        Button(auth.isSignedIn ? "Sync" : "Sign in…") {
            if auth.isSignedIn {
                Task { await sync.syncNow(now: Date()) }
            } else {
                showAccount()
            }
        }
        Button("Account…") { showAccount() }
    }
}
