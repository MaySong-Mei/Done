//
//  AISuggestionsCard.swift
//  Done
//

import SwiftUI

struct AISuggestionsCard: View {
    let suggestions: [AISuggestion]
    let isLoading: Bool
    let onRefresh: () -> Void
    let onAddEvent: (SuggestedEvent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                        .padding(.vertical, 16)
                    Spacer()
                }
            } else if suggestions.isEmpty {
                Text("Tap refresh to get AI-powered suggestions for your schedule.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(suggestions) { suggestion in
                    suggestionRow(suggestion)
                    if suggestion.id != suggestions.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "sparkles")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("AI Suggestions")
                .font(.headline)
            Spacer()
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .disabled(isLoading)
        }
    }

    private func suggestionRow(_ suggestion: AISuggestion) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: suggestion.icon)
                .font(.subheadline)
                .foregroundStyle(.tint)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.title)
                    .font(.subheadline.weight(.semibold))
                Text(suggestion.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let event = suggestion.suggestedEvent {
                Button {
                    onAddEvent(event)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
