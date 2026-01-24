//
//  TypingSubtitleView.swift
//  Done
//
//  Displays a line of text with a typewriter effect, completing even if the
//  run loop switches modes (e.g., during scroll/animations).
//

import SwiftUI

/// 功能： Displays subtitle text with a typewriter-style reveal.
struct TypingSubtitleView: View {
    let text: String
    var font: Font = .footnote
    var color: Color = .secondary
    let progress: Int

    var body: some View {
        Text(String(text.prefix(progress)))
            .font(font)
            .foregroundStyle(color)
    }
}
