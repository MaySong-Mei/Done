//
//  RootView.swift
//  DoneMac
//
//  Phase 1 placeholder shell. Touches one shared symbol so a broken
//  shared-layer link fails here, not silently at a later phase.
//

import SwiftUI

struct RootView: View {
    private var storagePath: String {
        (try? EventStorageLocation.applicationSupport().path) ?? "unresolved"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("DoneMac")
                .font(.largeTitle)
            Text("Phase 1 — shared layer bring-up")
                .foregroundStyle(.secondary)
            Text("Storage container: \(storagePath)")
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
        .padding(24)
        .frame(minWidth: 480, minHeight: 240, alignment: .topLeading)
    }
}
