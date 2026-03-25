//
//  AppleCalendarHeaderView.swift
//  Done
//
//  Apple Calendar inspired floating header capsules.
//

import SwiftUI

func calendarRangeModeMenuOptions() -> [RangeMode] {
    [.day, .threeDay, .week, .month]
}

func calendarRangeModeMenuLabel(for mode: RangeMode) -> String {
    switch mode {
    case .day:
        return "Day"
    case .threeDay:
        return "3-Day"
    case .week:
        return "Week"
    case .month:
        return "Month"
    }
}

struct AppleCalendarHeaderView: View {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    let selectedDate: Date
    let rangeMode: RangeMode
    let leftCapsuleTitle: String
    let isCapsulesVisible: Bool
    let isActionCapsuleVisible: Bool
    var onMonthTap: () -> Void
    var onSelectRangeMode: (RangeMode) -> Void
    @Binding var isAgenticCreateEnabled: Bool
    var onAgentTap: () -> Void
    var onSearchTap: () -> Void
    var onAddTap: () -> Void

    private var capsuleTransition: AnyTransition {
        accessibilityReduceMotion
            ? .opacity
            : .move(edge: .top).combined(with: .opacity)
    }

    private func capsuleOffsetY(isVisible: Bool) -> CGFloat {
        guard !accessibilityReduceMotion else { return 0 }
        return isVisible ? 0 : -6
    }

    var body: some View {
        SwiftUI.GlassEffectContainer(spacing: 10) {
            topRow
        }
        .frame(maxWidth: .infinity)
        .animation(accessibilityReduceMotion ? .none : .easeOut(duration: 0.18), value: isCapsulesVisible)
        .animation(accessibilityReduceMotion ? .none : .easeOut(duration: 0.18), value: isActionCapsuleVisible)
    }

    private var topRow: some View {
        HStack(spacing: 10) {
            if isCapsulesVisible {
                Button(action: onMonthTap) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                        Text(leftCapsuleTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .glassEffect(.regular.interactive(), in: Capsule())
                }
                .buttonStyle(.plain)
                .offset(y: capsuleOffsetY(isVisible: isCapsulesVisible))
                .transition(capsuleTransition)
            }

            Spacer(minLength: 0)

            if isActionCapsuleVisible {
                HStack(spacing: 10) {
                    Button(action: onAgentTap) {
                        Image(systemName: "sparkles")
                    }

                    Menu {
                        ForEach(calendarRangeModeMenuOptions(), id: \.self) { mode in
                            Button {
                                onSelectRangeMode(mode)
                            } label: {
                                if mode == rangeMode {
                                    Label(calendarRangeModeMenuLabel(for: mode), systemImage: "checkmark")
                                } else {
                                    Text(calendarRangeModeMenuLabel(for: mode))
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "rectangle.grid.1x2")
                    }

                    Button(action: onSearchTap) {
                        Image(systemName: "magnifyingglass")
                    }

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isAgenticCreateEnabled.toggle()
                        }
                    } label: {
                        Image(systemName: isAgenticCreateEnabled ? "wand.and.stars" : "square.and.pencil")
                            .contentTransition(.symbolEffect(.replace))
                            .offset(y: -1)
                    }

                    Button(action: onAddTap) {
                        Image(systemName: "plus")
                    }
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .frame(height: 40)
                .glassEffect(.regular.interactive(), in: Capsule())
                .offset(y: capsuleOffsetY(isVisible: isActionCapsuleVisible))
                .transition(capsuleTransition)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
