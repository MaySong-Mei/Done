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

    var body: some View {
        Group {
            if runtime == nil {
                Text("Storage unavailable — running detached")
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let surface {
                VStack(spacing: 0) {
                    controls(surface)
                    CalendarCanvasView(surface: surface)
                }
            } else {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
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
        }
        .onDisappear {
            surface?.deactivate()
            surface = nil
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
            Spacer()
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
