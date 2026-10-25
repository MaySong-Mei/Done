//
//  RichTextView.swift
//  DoneMac
//
//  The Mac's stand-in for the phone's RichTextView (Done/Views/Agent), which
//  renders chat replies with the MarkdownUI and LaTeXSwiftUI packages the
//  Mac target does not link. Paragraphs render as Foundation inline
//  Markdown (bold, italic, code, links); math shows as its source text.
//

import SwiftUI

struct RichTextView: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.paragraphs(content).enumerated()), id: \.offset) { _, paragraph in
                Text(Self.attributed(paragraph))
                    .font(.system(size: 15))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func paragraphs(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func attributed(_ paragraph: String) -> AttributedString {
        (try? AttributedString(markdown: paragraph,
                               options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(paragraph)
    }
}
