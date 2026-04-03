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

/// 功能： Renders a reusable glass-styled container around arbitrary content.
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

private struct AdaptivePanelWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct AdaptivePanelPair<Primary: View, Secondary: View>: View {
    var spacing: CGFloat = 12
    var horizontalThreshold: CGFloat = 440
    @ViewBuilder var primary: Primary
    @ViewBuilder var secondary: Secondary

    @State private var availableWidth: CGFloat = 0

    init(
        spacing: CGFloat = 12,
        horizontalThreshold: CGFloat = 440,
        @ViewBuilder primary: () -> Primary,
        @ViewBuilder secondary: () -> Secondary
    ) {
        self.spacing = spacing
        self.horizontalThreshold = horizontalThreshold
        self.primary = primary()
        self.secondary = secondary()
    }

    private var layout: AnyLayout {
        if availableWidth >= horizontalThreshold {
            AnyLayout(HStackLayout(alignment: .top, spacing: spacing))
        } else {
            AnyLayout(VStackLayout(alignment: .leading, spacing: spacing))
        }
    }

    var body: some View {
        layout {
            primary
                .frame(maxWidth: .infinity, alignment: .topLeading)
            secondary
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: AdaptivePanelWidthPreferenceKey.self, value: proxy.size.width)
            }
        }
        .onPreferenceChange(AdaptivePanelWidthPreferenceKey.self) { newValue in
            availableWidth = newValue
        }
    }
}

struct CalendarHumanEffortDescriptor: Equatable {
    let title: String
    let subtitle: String
}

private func calendarCurrentLanguage() -> AppLanguage {
    AppLanguage(
        rawValue: UserDefaults.standard.string(forKey: AppSettingsLocale.languageKey) ?? AppLanguage.english.rawValue
    ) ?? .english
}

func calendarHumanEffortDescriptor(for value: Int) -> CalendarHumanEffortDescriptor {
    switch calendarCurrentLanguage() {
    case .english:
        switch value {
        case 1:
            return CalendarHumanEffortDescriptor(
                title: "Easy",
                subtitle: "Barely took effort."
            )
        case 2:
            return CalendarHumanEffortDescriptor(
                title: "Light",
                subtitle: "A little effort, still comfortable."
            )
        case 3:
            return CalendarHumanEffortDescriptor(
                title: "Steady",
                subtitle: "A normal amount of energy."
            )
        case 4:
            return CalendarHumanEffortDescriptor(
                title: "Demanding",
                subtitle: "Took solid effort to stay on it."
            )
        case 5:
            return CalendarHumanEffortDescriptor(
                title: "Draining",
                subtitle: "This felt genuinely hard."
            )
        default:
            return CalendarHumanEffortDescriptor(
                title: "Effort",
                subtitle: "How demanding this felt."
            )
        }
    case .chinese:
        switch value {
        case 1:
            return CalendarHumanEffortDescriptor(
                title: "很轻松",
                subtitle: "几乎没怎么费力。"
            )
        case 2:
            return CalendarHumanEffortDescriptor(
                title: "还算轻松",
                subtitle: "需要投入一点，但整体轻松。"
            )
        case 3:
            return CalendarHumanEffortDescriptor(
                title: "正常投入",
                subtitle: "这次大致是正常消耗。"
            )
        case 4:
            return CalendarHumanEffortDescriptor(
                title: "挺费劲",
                subtitle: "需要明显用力才能推进。"
            )
        case 5:
            return CalendarHumanEffortDescriptor(
                title: "很吃力",
                subtitle: "这次确实很耗人。"
            )
        default:
            return CalendarHumanEffortDescriptor(
                title: "投入程度",
                subtitle: "标记一下这次有多费力。"
            )
        }
    }
}

func calendarHumanEffortPrompt() -> String {
    switch calendarCurrentLanguage() {
    case .english:
        return "Drag to mark how demanding this felt."
    case .chinese:
        return "拖一下，标记这次有多费力。"
    }
}

func calendarHumanEffortRangeLabels() -> (leading: String, trailing: String) {
    switch calendarCurrentLanguage() {
    case .english:
        return ("Lighter", "Heavier")
    case .chinese:
        return ("轻松", "吃力")
    }
}

struct CalendarEffortScrubber: View {
    @Binding var value: Int?
    var tint: Color = .accentColor

    private let allowedValues = Array(1...5)
    private let trackInset: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                let availableWidth = max(geo.size.width - trackInset * 2, 1)
                let thumbValue = value ?? 3
                let thumbX = pointX(for: thumbValue, width: availableWidth)

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.12))
                        .frame(height: 8)
                        .padding(.horizontal, trackInset)

                    if let value {
                        Capsule()
                            .fill(tint.opacity(0.22))
                            .frame(width: max(0, pointX(for: value, width: availableWidth) - trackInset), height: 8)
                            .offset(x: trackInset, y: 0)
                    }

                    ForEach(allowedValues, id: \.self) { effortValue in
                        let isSelected = value == effortValue
                        Button {
                            withAnimation(.easeInOut(duration: 0.14)) {
                                value = isSelected ? nil : effortValue
                            }
                        } label: {
                            Circle()
                                .fill(isSelected ? tint : Color.white.opacity(0.88))
                                .overlay {
                                    Circle()
                                        .stroke(
                                            isSelected ? tint.opacity(0.75) : Color.secondary.opacity(0.18),
                                            lineWidth: isSelected ? 1 : 0.8
                                        )
                                }
                                .frame(width: isSelected ? 12 : 10, height: isSelected ? 12 : 10)
                                .shadow(color: .black.opacity(isSelected ? 0.16 : 0.06), radius: 4, x: 0, y: 2)
                                .frame(width: 38, height: 38)
                        }
                        .buttonStyle(.plain)
                        .position(x: pointX(for: effortValue, width: availableWidth), y: geo.size.height / 2)
                    }

                    Circle()
                        .fill(.ultraThickMaterial)
                        .overlay {
                            Circle()
                                .stroke(
                                    value == nil ? Color.secondary.opacity(0.22) : tint.opacity(0.38),
                                    lineWidth: 1
                                )
                        }
                        .overlay {
                            Circle()
                                .fill(value == nil ? Color.secondary.opacity(0.18) : tint)
                                .padding(5)
                        }
                        .frame(width: 30, height: 30)
                        .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
                        .position(x: thumbX, y: geo.size.height / 2)
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let nextValue = nearestValue(for: drag.location.x, width: availableWidth)
                            guard nextValue != value else { return }
                            value = nextValue
                        }
                )
            }
            .frame(height: 38)

            let labels = calendarHumanEffortRangeLabels()
            HStack {
                Text(labels.leading)
                Spacer()
                Text(labels.trailing)
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
        }
    }

    private func pointX(for value: Int, width: CGFloat) -> CGFloat {
        guard allowedValues.count > 1 else { return trackInset }
        let progress = CGFloat(value - 1) / CGFloat(allowedValues.count - 1)
        return trackInset + width * progress
    }

    private func nearestValue(for locationX: CGFloat, width: CGFloat) -> Int {
        let progress = min(max((locationX - trackInset) / width, 0), 1)
        return min(max(Int(round(progress * CGFloat(allowedValues.count - 1))) + 1, 1), 5)
    }
}

/// 功能： Applies a glass effect background and shape clipping to content.
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
