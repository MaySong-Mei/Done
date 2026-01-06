//
//  TimelineViewModel.swift
//  Done
//
//  Created by Shiqi Liu on 1/3/26.
//

import Foundation
import Combine

@MainActor
final class TimelineViewModel: ObservableObject {
    enum DisplayMode: Int, CaseIterable {
        case day = 1
        case threeDays = 3
        case week = 7
    }

    @Published var viewMode: DisplayMode = .day
    @Published var centerDate: Date = Calendar.current.startOfDay(for: Date())
    private var isMagnifying = false
    private let renderBufferDays = 30
    private let cycleOrder: [DisplayMode] = [.day, .threeDays, .week]
    private var cycleDirection: Int = 1

    var dayCount: Int { viewMode.rawValue }

    var currentVisibleDates: [Date] {
        let cal = Calendar.current
        let offset = dayCount / 2
        return (-offset...offset).compactMap { i in
            cal.date(byAdding: .day, value: i, to: centerDate)
        }
    }

    var renderDates: [Date] {
        let cal = Calendar.current
        let offset = (dayCount / 2) + renderBufferDays
        return (-offset...offset).compactMap { i in
            cal.date(byAdding: .day, value: i, to: centerDate)
        }
    }

    func beginMagnification() {
        isMagnifying = true
    }

    func handleMagnificationGestureEnded(_ value: CGFloat) {
        guard isMagnifying else { return }
        isMagnifying = false

        let currentCenter = centerDate

        if value < 0.95 {
            switch viewMode {
            case .day:
                viewMode = .threeDays
            case .threeDays:
                viewMode = .week
            case .week:
                break
            }
        } else if value > 1.05 {
            switch viewMode {
            case .week:
                viewMode = .threeDays
            case .threeDays:
                viewMode = .day
            case .day:
                break
            }
        }

        centerDate = Calendar.current.startOfDay(for: currentCenter)
    }

    func cycleViewMode() {
        guard let currentIndex = cycleOrder.firstIndex(of: viewMode) else { return }
        var nextIndex = currentIndex + cycleDirection

        if nextIndex >= cycleOrder.count {
            cycleDirection = -1
            nextIndex = currentIndex + cycleDirection
        } else if nextIndex < 0 {
            cycleDirection = 1
            nextIndex = currentIndex + cycleDirection
        }

        viewMode = cycleOrder[nextIndex]
        centerDate = Calendar.current.startOfDay(for: centerDate)
    }
}
