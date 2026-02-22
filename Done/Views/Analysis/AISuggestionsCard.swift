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
                    .font(.system(size: 13))
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
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var header: some View {
        HStack {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("AI Suggestions")
                .font(.headline)
            Spacer()
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .disabled(isLoading)
        }
    }

    private func suggestionRow(_ suggestion: AISuggestion) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: suggestion.icon)
                .font(.system(size: 16))
                .foregroundStyle(.tint)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.title)
                    .font(.system(size: 14, weight: .semibold))
                Text(suggestion.detail)
                    .font(.system(size: 13))
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
