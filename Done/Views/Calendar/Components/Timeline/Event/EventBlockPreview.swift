//
//  EventBlockPreview.swift
//  Done
//
//  Read-only event block styling for the timeline.
//

import SwiftUI

/// 功能： Renders a read-only event block in the timeline grid.
struct EventBlockPreview: View {
    let event: Event
    let color: Color
    let showText: Bool

    var body: some View {
        content
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

    @ViewBuilder
    private var content: some View {
        if showText {
            Text(event.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)
                .padding(8)
        } else {
            Color.clear
        }
    }
}
