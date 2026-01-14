//
//  GlassCardView.swift
//  Done
//
//  Small visual component used by `CalendarPageView`.
//  Renders the decorative glass card at the top of the calendar page.
//
//  Created by opencode and yifan mei on 1/14/26.
//

import SwiftUI

struct GlassCardView: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.white.opacity(0.6), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 16, x: 0, y: 8)
    }
}
