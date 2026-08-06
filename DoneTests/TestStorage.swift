//
//  TestStorage.swift
//  DoneTests
//
//  Paired setup/teardown for a test's storage.
//
//  `DoneTests` is a HOST-APP bundle: every test runs inside Done.app, in
//  Done.app's container. Before this existed, isolation was
//  `UserDefaults(suiteName:)` plus `removePersistentDomain` — which stops
//  covering anything the moment the store keeps its data in files.
//
//  Two rules, both learned the hard way:
//
//  1. `reset` must run BEFORE the store is constructed. Several suites use a
//     FIXED name (e.g. "CalendarDragLogicTests.createInterrupt") rather than a
//     per-run UUID, so a directory left behind by the previous run would be
//     read straight into the next one.
//  2. Every `reset` needs a matching `tearDown`, or the simulator container
//     accumulates a directory per test forever.
//

import Foundation
@testable import Done

enum TestStorage {
    /// Clean slate: wipes both the UserDefaults suite and the storage
    /// directory, and returns the location to hand to `EventStore(storage:)`.
    @discardableResult
    static func reset(_ name: String) -> EventStorageLocation {
        let location = EventStorageLocation.isolated(name: name)
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        EventStorageLocation.destroy(location)
        return location
    }

    /// The teardown half. Safe to call more than once.
    static func tearDown(_ name: String) {
        UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        EventStorageLocation.destroy(.isolated(name: name))
    }
}
