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

    private let stepCount = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geo in
                let trackWidth = max(geo.size.width, 1)
                let thumbValue = value ?? 3
                let progress = CGFloat(thumbValue - 1) / CGFloat(stepCount - 1)
                let fillWidth = trackWidth * progress

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: trackWidth, height: 4)

                    if value != nil {
                        Capsule()
                            .fill(tint.opacity(0.4))
                            .frame(width: fillWidth, height: 4)
                    }

                    ForEach(0..<stepCount, id: \.self) { step in
                        let stepProgress = CGFloat(step) / CGFloat(stepCount - 1)
                        let isAtOrBefore = value != nil && step + 1 <= (value ?? 0)
                        Circle()
                            .fill(isAtOrBefore ? tint : Color.primary.opacity(0.35))
                            .frame(width: 6, height: 6)
                            .position(x: trackWidth * stepProgress, y: geo.size.height / 2)
                    }

                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(.ultraThickMaterial)
                        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(value == nil ? Color.secondary.opacity(0.4) : tint).padding(3))
                        .frame(width: 8, height: 22)
                        .position(x: fillWidth, y: geo.size.height / 2)
                        .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let nextValue = nearestValue(for: drag.location.x, trackWidth: trackWidth)
                            guard nextValue != value else { return }
                            withAnimation(.easeInOut(duration: 0.14)) {
                                value = nextValue
                            }
                        }
                )
            }
            .frame(height: 22)

            let labels = calendarHumanEffortRangeLabels()
            HStack {
                Text(labels.leading)
                Spacer()
                Text(labels.trailing)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func nearestValue(for locationX: CGFloat, trackWidth: CGFloat) -> Int {
        let progress = min(max(locationX / trackWidth, 0), 1)
        return Int(round(progress * CGFloat(stepCount - 1))) + 1
    }
}

/// 功能： Applies the iOS 26 Liquid Glass effect to a card-shaped container.
/// Renamed-in-place wrapper: prior version stacked `.ultraThinMaterial` + stroke
/// + tint manually, which read flatter than the system `.glassEffect()` used on
/// the page-title pills. Using the real API keeps cards visually consistent
/// with the rest of the Liquid Glass chrome.
struct GlassEffectContainer<Content: View>: View {
    var cornerRadius: CGFloat = 20
    @ViewBuilder var content: Content

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        content
            .background(Color.black.opacity(0.001), in: shape)
            .glassEffect(.regular, in: shape)
    }
}
