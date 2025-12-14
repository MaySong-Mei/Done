//
//  TimeInterval+Format.swift
//  Done
//
//  Created by Claude on 12/14/25.
//

import Foundation

extension TimeInterval {
    /// Formats the duration as "Xh Ym" (e.g., "2h 30m")
    /// If less than 1 hour, returns "Ym" (e.g., "45m")
    func formatAsHoursMinutes() -> String {
        let hours = Int(self) / 3600
        let minutes = Int(self) % 3600 / 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    /// Formats the duration as "HH:MM:SS" or "MM:SS"
    /// Used for active timers that show seconds
    func formatAsTimer() -> String {
        let hours = Int(self) / 3600
        let minutes = Int(self) % 3600 / 60
        let seconds = Int(self) % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
}
