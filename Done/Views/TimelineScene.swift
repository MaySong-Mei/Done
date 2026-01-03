//
//  TimelineScene.swift
//  Done
//
//  Created by Created by Shiqi Liu on 1/3/26.
//

import SwiftUI

struct TimelineScene: View {
    var body: some View {
        VStack(spacing: 0) {
            headerCard
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)

            bodyScroll
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 8)
        }
        .background(Color(.systemBackground))
    }

    // MARK: Body Scroll
    private var bodyScroll: some View {
        ScrollView(.vertical, showsIndicators: true) {
            Color.clear
                .frame(height: 0)
        }
    }

    // MARK: Header Card
    private var headerCard: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.ultraThinMaterial)
            .frame(height: 96)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 6)
    }
}
