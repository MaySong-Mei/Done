//
//  RootView.swift
//  DoneMac
//
//  Phase 2 shell: shows what the truth layer loaded. Static snapshot on
//  purpose — surfaces with real observation arrive in Phase 3.
//

import SwiftUI

struct RootView: View {
    let runtime: MacAppRuntime?
    @State private var loadedEventCount: Int?
    @State private var frozenSlotCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("DoneMac")
                .font(.largeTitle)
            Text("Phase 2 — truth layer")
                .foregroundStyle(.secondary)
            if runtime == nil {
                Text("Storage unavailable — running detached")
                    .foregroundStyle(.red)
            } else if let loadedEventCount {
                Text("\(loadedEventCount) calendar events loaded")
                    .font(.body.monospacedDigit())
                if frozenSlotCount > 0 {
                    Text("\(frozenSlotCount) slot(s) frozen")
                        .foregroundStyle(.red)
                }
            } else {
                Text("Loading…")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 240, alignment: .topLeading)
        .task {
            guard let runtime else { return }
            // start() runs from DoneMacApp; poll-free wait for isLoaded via
            // a cheap check after our own start call completes there.
            while !(runtime.store.isLoaded) {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            loadedEventCount = runtime.store.calendarEvents.count
            frozenSlotCount = runtime.store.frozenSlots.count
        }
    }
}
