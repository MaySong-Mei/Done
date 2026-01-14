//
//  CalendarEventBlockView.swift
//  Done
//
//  Visual block representing one event on the timeline.
//  Positioning and sizing are handled by the parent day view.
//
//  Created by opencode and yifan mei on 1/14/26.
//

import SwiftUI

/// Renders the title and styling for a single event block inside the timeline.
struct CalendarEventBlockView: View {
    let event: Event
    let color: Color

    var body: some View {
        Text(event.title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.primary)
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color.opacity(0.25))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(color.opacity(0.4), lineWidth: 1)
            )
    }
}
