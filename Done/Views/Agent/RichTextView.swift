//
//  RichTextView.swift
//  Done
//

import SwiftUI
import MarkdownUI
import LaTeXSwiftUI

struct RichTextView: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(segments.indices, id: \.self) { i in
                switch segments[i] {
                case .markdown(let text):
                    Markdown(text)
                        .markdownTextStyle {
                            FontSize(15)
                        }
                case .latex(let formula):
                    LaTeX("$$\(formula)$$")
                        .parsingMode(.all)
                        .blockMode(.alwaysInline)
                }
            }
        }
    }

    private var segments: [ContentSegment] {
        parseContent(content)
    }
}

private enum ContentSegment {
    case markdown(String)
    case latex(String)
}

private func parseContent(_ content: String) -> [ContentSegment] {
    var segments: [ContentSegment] = []
    let delimiter = "$$"
    var remaining = content

    while let startRange = remaining.range(of: delimiter) {
        // Text before the delimiter is markdown
        let before = String(remaining[remaining.startIndex..<startRange.lowerBound])
        if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            segments.append(.markdown(before))
        }

        remaining = String(remaining[startRange.upperBound...])

        // Find closing delimiter
        if let endRange = remaining.range(of: delimiter) {
            let formula = String(remaining[remaining.startIndex..<endRange.lowerBound])
            if !formula.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(.latex(formula))
            }
            remaining = String(remaining[endRange.upperBound...])
        } else {
            // No closing delimiter — treat the rest as markdown (including the opening $$)
            segments.append(.markdown(delimiter + remaining))
            remaining = ""
        }
    }

    // Any remaining text is markdown
    if !remaining.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        segments.append(.markdown(remaining))
    }

    // If nothing was parsed, return the whole content as markdown
    if segments.isEmpty && !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        segments.append(.markdown(content))
    }

    return segments
}
