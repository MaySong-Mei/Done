//
//  CarryGhostView.swift
//  Done
//
//  Created by Codex on 3/10/26.
//

import SwiftUI

struct CarryGhostView: View {
    let entry: TimeEntry
    let displayStart: Date
    let displayEnd: Date
    let height: CGFloat
    let width: CGFloat
    let showsLabels: Bool
    let type: TimelineEventType
    private let cornerRadius: CGFloat = 6

    var body: some View {
        TimelineEventContentView(
            entry: entry,
            displayStart: displayStart,
            displayEnd: displayEnd,
            height: height,
            width: width,
            showsLabels: showsLabels,
            type: type,
            cornerRadius: cornerRadius
        )
        .scaleEffect(1.03)
        .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 3)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
        )
        .allowsHitTesting(false)
    }
}
