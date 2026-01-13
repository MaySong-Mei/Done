//
//  CalendarView.swift
//  Done
//
//  Created by Shiqi Liu on 1/14/26.
//

import SwiftUI

struct CalendarView: View {
    var body: some View {
        GeometryReader { proxy in
            let topHeight = max(120, proxy.size.height * 0.12)

            VStack(spacing: 16) {
                GlassCard()
                    .frame(height: topHeight)
                    .padding(.horizontal, 16)
                    .padding(.top, 16)

                ScrollView {
                    Color.clear
                        .frame(height: 1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct GlassCard: View {
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
