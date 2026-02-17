//
//  AppleCalendarHeaderView.swift
//  Done
//
//  Apple Calendar inspired floating header capsules.
//

import SwiftUI

func calendarRangeModeMenuOptions() -> [RangeMode] {
    [.day, .threeDay, .week]
}

func calendarRangeModeMenuLabel(for mode: RangeMode) -> String {
    switch mode {
    case .day:
        return "Day"
    case .threeDay:
        return "3-Day"
    case .week:
        return "Week"
    }
}

struct AppleCalendarHeaderView: View {
    let selectedDate: Date
    let rangeMode: RangeMode
    let leftCapsuleTitle: String
    let collapseProgress: CGFloat
    var onMonthTap: () -> Void
    var onSelectRangeMode: (RangeMode) -> Void
    var onAgentTap: () -> Void
    var onSearchTap: () -> Void
    var onAddTap: () -> Void

    private var clampedCollapseProgress: CGFloat {
        clamp(collapseProgress, 0, 1)
    }

    private var topRowHeight: CGFloat {
        lerp(40, 0, clampedCollapseProgress)
    }

    private var topRowOpacity: CGFloat {
        lerp(1, 0.12, clampedCollapseProgress)
    }

    private var topRowScale: CGFloat {
        lerp(1, 0.97, clampedCollapseProgress)
    }

    var body: some View {
        topRow
        .animation(.easeOut(duration: 0.2), value: clampedCollapseProgress)
    }

    private var topRow: some View {
        HStack(spacing: 10) {
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
                .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

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

                Button(action: onAddTap) {
                    Image(systemName: "plus")
                }
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .frame(height: max(0, topRowHeight), alignment: .top)
        .opacity(topRowOpacity)
        .scaleEffect(topRowScale, anchor: .top)
        .clipped()
        .accessibilityHidden(clampedCollapseProgress > 0.95)
    }
}
