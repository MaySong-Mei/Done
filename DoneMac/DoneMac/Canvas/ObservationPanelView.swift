//
//  ObservationPanelView.swift
//  DoneMac
//
//  The 观察站: live work-bill counters with tripwires on top — a nonzero
//  tripwire renders red. Judgment stays with the human; this just makes
//  the evidence one glance (the Fix Watch convention).
//

import SwiftUI

struct ObservationPanelView: View {
    let bill: MacWorkBill
    var onDone: () -> Void
    @State private var rows: [(String, Int, Bool)] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Observation")
                .font(.title3.bold())
            Text("Tripwires expect 0 — red means a regression alarm.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                    ForEach(rows, id: \.0) { name, value, isTripwire in
                        GridRow {
                            Text(name).font(.caption.monospaced())
                            Text("\(value)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(isTripwire && value > 0 ? .red : .primary)
                        }
                    }
                }
            }
            .frame(maxHeight: 320)
            HStack {
                Button("Refresh") { refresh() }
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { refresh() }
    }

    private func refresh() {
        let tripwireSet = Set(BillLog.tripwires)
        // Tripwires first, then the rest, both alphabetical.
        rows = MacWorkBill.Counter.allCases
            .map { ($0.rawValue, bill.count($0), tripwireSet.contains($0)) }
            .sorted { lhs, rhs in
                if lhs.2 != rhs.2 { return lhs.2 }
                return lhs.0 < rhs.0
            }
    }
}
