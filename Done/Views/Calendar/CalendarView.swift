//
//  CalendarView.swift
//  Done
//
//  Compatibility wrapper for the calendar tab entry.
//  Keep this type stable while the implementation lives in `CalendarPageView`.
//
//  Created by opencode and yifan mei on 1/14/26.
//

import SwiftUI

/// 功能： Provides the calendar tab entry point while delegating layout to `CalendarPageView`.
struct CalendarView: View {
    var body: some View {
        CalendarPageView()
    }
}
