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

    var dayCount: Int { viewMode.rawValue }

    var currentVisibleDates: [Date] {
        let cal = Calendar.current
        let offset = dayCount / 2
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
}
