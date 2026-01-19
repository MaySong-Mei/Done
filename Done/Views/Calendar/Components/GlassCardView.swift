//
//  GlassCardView.swift
//  Done
//
//  Reusable glass-styled container. Apply your own content; padding/size
//  are controlled by the caller so this can be used beyond the calendar page.
//
//  Created by opencode and yifan mei on 1/14/26.
//

import SwiftUI

struct GlassCardView<Content: View>: View {
    var cornerRadius: CGFloat = 20
    var contentPadding: CGFloat = 12
    @ViewBuilder var content: Content

    init(
        cornerRadius: CGFloat = 20,
        contentPadding: CGFloat = 12,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.contentPadding = contentPadding
        self.content = content()
    }

    var body: some View {
        GlassEffectContainer(cornerRadius: cornerRadius) {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(contentPadding)
        }
        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 8)
    }
}

struct GlassEffectContainer<Content: View>: View {
    var cornerRadius: CGFloat = 20
    @ViewBuilder var content: Content

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        content
            .background {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay {
                        shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.8)
                    }
                    .overlay {
                        shape.fill(.white.opacity(0.06))
                    }
            }
            .clipShape(shape)
    }
}
