//
//  MacPersistence.swift
//  DoneMac
//
//  File I/O off the main thread, with revision-gated coalescing: the actor
//  keeps only the LATEST submitted snapshot per slot, so a burst of commits
//  costs one write, and an equal generation costs zero bytes (#219 concept
//  3 made structural — the O(1) dirty check the iOS backup path lacked).
//
//  Wraps the shared DurableEventStorage engine (atomic rename + checksum +
//  shrink guard) in the Mac sandbox container.
//

import Foundation

actor MacPersistence {
    struct LoadResult: Sendable {
        var calendarEvents: [Event]
        var todoLists: [TodoList]
        var dominoStamp: Date?
        var sidecar: SidecarFile
        var frozenSlots: [StorageSlot]
        var sidecarWasUnreadable: Bool
    }

    struct Stats: Equatable, Sendable {
        var slotWrites = 0
        var slotWriteBytes = 0
        /// Byte-identical payload — engine skipped the write.
        var skippedIdenticalWrites = 0
        /// A newer snapshot arrived before this one drained — never hit disk.
        var supersededSubmissions = 0
        /// Submitted generation not newer than the last accepted — zero bytes.
        var redundantSubmissions = 0
        var failedWrites = 0
        var heartbeatWrites = 0
        var sidecarWrites = 0
    }

    private let storage: DurableEventStorage
    private let sidecarFile: AtomicValueFile<SidecarFile>

    private var lastAcceptedGeneration: [StorageSlot: UInt64] = [:]
    private var lastSidecarGeneration: UInt64 = 0
    private var pendingCalendar: (rows: [Event], generation: UInt64, dominoStamp: Date?)?
    private var pendingTodoLists: (rows: [TodoList], generation: UInt64)?
    private var pendingSidecar: (value: SidecarFile, generation: UInt64)?
    private var drainScheduled = false
    private(set) var stats = Stats()

    /// The coalescing window: submissions landing inside it collapse to one
    /// write. Tests submit + `flush()` explicitly, so the exact value only
    /// shapes steady-state write frequency, never correctness.
    private let drainDelayNanoseconds: UInt64

    init(location: EventStorageLocation, drainDelayNanoseconds: UInt64 = 40_000_000) throws {
        storage = DurableEventStorage(location: location, legacyDefaults: nil)
        // NEXT TO the engine's directory, never inside it: the engine's
        // sweepUnknownEntries deletes anything off its whitelist there
        // (same contract that pushed EventTypeCatalog out — see
        // EventStorageLocation.productionDirectoryName's doc).
        let storageDirectory = try location.directoryURL()
        let sidecarDirectory = storageDirectory.deletingLastPathComponent()
            .appendingPathComponent(storageDirectory.lastPathComponent + "-Sidecar", isDirectory: true)
        sidecarFile = AtomicValueFile<SidecarFile>(directory: sidecarDirectory, filename: "revision-sidecar.json")
        self.drainDelayNanoseconds = drainDelayNanoseconds
    }

    // MARK: - Load

    func loadAll() -> LoadResult {
        var frozen: [StorageSlot] = []
        var events: [Event] = []
        var todoLists: [TodoList] = []

        switch storage.read(.calendarEvents, as: Event.self) {
        case .fresh: break
        case .loaded(let envelope, _): events = envelope.rows
        case .unreadable: frozen.append(.calendarEvents)
        }
        switch storage.read(.todoLists, as: TodoList.self) {
        case .fresh: break
        case .loaded(let envelope, _): todoLists = envelope.rows
        case .unreadable: frozen.append(.todoLists)
        }

        // Same combination rule as iOS resolveDominoLastPush: both sources
        // state "aligned as of this moment"; the newer statement wins.
        var stamp = storage.persistedDominoStamp()
        if let beat = storage.readDominoHeartbeat() {
            stamp = max(stamp ?? beat, beat)
        }

        var sidecar = SidecarFile()
        var sidecarUnreadable = false
        switch sidecarFile.read() {
        case .fresh: break
        case .loaded(let value, _): sidecar = value
        case .unreadable: sidecarUnreadable = true
        }

        return LoadResult(
            calendarEvents: events,
            todoLists: todoLists,
            dominoStamp: stamp,
            sidecar: sidecar,
            frozenSlots: frozen,
            sidecarWasUnreadable: sidecarUnreadable
        )
    }

    // MARK: - Submit (latest-wins coalescing)

    func submitCalendarEvents(_ rows: [Event], generation: UInt64, dominoStamp: Date?) {
        if pendingCalendar != nil { stats.supersededSubmissions += 1 }
        pendingCalendar = (rows, generation, dominoStamp)
        scheduleDrain()
    }

    func submitTodoLists(_ rows: [TodoList], generation: UInt64) {
        if pendingTodoLists != nil { stats.supersededSubmissions += 1 }
        pendingTodoLists = (rows, generation)
        scheduleDrain()
    }

    func submitSidecar(_ value: SidecarFile, generation: UInt64) {
        if pendingSidecar != nil { stats.supersededSubmissions += 1 }
        pendingSidecar = (value, generation)
        scheduleDrain()
    }

    func writeDominoHeartbeat(_ time: Date) {
        do {
            try storage.writeDominoHeartbeat(time)
            stats.heartbeatWrites += 1
        } catch {
            stats.failedWrites += 1
        }
    }

    /// Drain everything pending. Callers that must not lose data (terminate,
    /// tests) await this; steady-state drains happen via scheduleDrain.
    func flush() {
        drainScheduled = false
        if let pending = pendingCalendar {
            pendingCalendar = nil
            drainCalendar(pending)
        }
        if let pending = pendingTodoLists {
            pendingTodoLists = nil
            drainTodoLists(pending)
        }
        if let pending = pendingSidecar {
            pendingSidecar = nil
            drainSidecar(pending)
        }
    }

    // MARK: - Drain

    private func scheduleDrain() {
        guard !drainScheduled else { return }
        drainScheduled = true
        // A real delay, not just the actor mailbox hop: awaited submits
        // arrive one hop apart, so a mailbox-only window collapses nothing.
        let delay = drainDelayNanoseconds
        Task {
            try? await Task.sleep(nanoseconds: delay)
            self.flush()
        }
    }

    private func drainCalendar(_ pending: (rows: [Event], generation: UInt64, dominoStamp: Date?)) {
        guard pending.generation > (lastAcceptedGeneration[.calendarEvents] ?? 0) else {
            stats.redundantSubmissions += 1
            return
        }
        do {
            let receipt = try storage.commit(
                pending.rows, to: .calendarEvents,
                dominoLastPush: pending.dominoStamp
            )
            lastAcceptedGeneration[.calendarEvents] = pending.generation
            record(receipt)
        } catch {
            stats.failedWrites += 1
        }
    }

    private func drainTodoLists(_ pending: (rows: [TodoList], generation: UInt64)) {
        guard pending.generation > (lastAcceptedGeneration[.todoLists] ?? 0) else {
            stats.redundantSubmissions += 1
            return
        }
        do {
            let receipt = try storage.commit(pending.rows, to: .todoLists)
            lastAcceptedGeneration[.todoLists] = pending.generation
            record(receipt)
        } catch {
            stats.failedWrites += 1
        }
    }

    private func drainSidecar(_ pending: (value: SidecarFile, generation: UInt64)) {
        guard pending.generation > lastSidecarGeneration else {
            stats.redundantSubmissions += 1
            return
        }
        do {
            let bytes = try sidecarFile.commit(pending.value)
            lastSidecarGeneration = pending.generation
            stats.sidecarWrites += 1
            stats.slotWriteBytes += bytes
        } catch {
            stats.failedWrites += 1
        }
    }

    private func record(_ receipt: CommitReceipt) {
        if receipt.skipped {
            stats.skippedIdenticalWrites += 1
        } else {
            stats.slotWrites += 1
            stats.slotWriteBytes += receipt.bytes
        }
    }
}
