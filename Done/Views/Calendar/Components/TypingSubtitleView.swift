//
//  TypingSubtitleView.swift
//  Done
//
//  Displays a line of text with a typewriter effect, completing even if the
//  run loop switches modes (e.g., during scroll/animations).
//

import SwiftUI

struct TypingSubtitleView: View {
    let text: String
    var font: Font = .footnote
    var color: Color = .secondary
    var interval: TimeInterval = 0.05
    @Binding var progress: Int
    var restartToken: UUID

    init(
        text: String,
        font: Font = .footnote,
        color: Color = .secondary,
        interval: TimeInterval = 0.05,
        progress: Binding<Int>,
        restartToken: UUID
    ) {
        self.text = text
        self.font = font
        self.color = color
        self.interval = interval
        self._progress = progress
        self.restartToken = restartToken
    }

    var body: some View {
        Text(String(text.prefix(progress)))
            .font(font)
            .foregroundStyle(color)
            .task(id: restartToken) {
                progress = min(progress, text.count)
                guard !text.isEmpty else { return }
                guard progress < text.count else { return }

                let ns = UInt64(max(0.001, interval) * 1_000_000_000)
                let start = min(progress + 1, text.count)
                for i in start...text.count {
                    try? await Task.sleep(nanoseconds: ns)
                    if Task.isCancelled { return }
                    progress = i
                }
            }
    }
}
