//
//  GlassCardView.swift
//  Done
//
//  Small visual component used by `CalendarPageView`.
//  Renders the decorative glass card at the top of the calendar page.
//
//  Created by opencode and yifan mei on 1/14/26.
//

import SwiftUI

struct GlassCardView: View {
    var body: some View {
        GlassEffectContainer() {
            VStack(alignment: .leading, spacing: 8) {
                Text("Calendar")
                    .font(.title2.bold())
                Text("View and manage your events")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading) // 关键：撑开并左对齐
        }
        .frame(height: 72) // 可选：让它像“header”
        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 8) // 关键：阴影给容器
        .padding(.horizontal, 16) // 可选：和页面边缘留空
    }
}


struct GlassEffectContainer<Content: View>: View {
    var cornerRadius: CGFloat = 20
    @ViewBuilder var content: Content
    // 这个地方定义了一个泛型视图容器，允许传入任意视图内容，并应用玻璃效果和圆角。
    // 这个content为什么需要呢？因为我们希望这个容器可以包裹任意视图内容，而不是固定某个视图。

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        content
        // content的含义是：传入的视图内容。技术上用法是 SwiftUI 的 ViewBuilder 特性，允许我们传入任意视图作为内容。
        // conent的内容在 body 内部被包装在一个玻璃效果的容器中。
            .background {
                shape
                    .glassEffect(.clear.interactive(), in: shape, )
                    // 关键：玻璃效果背景
                    // 这里glassEffect有两个参数，第一个是效果强度，第二个是形状。
                    // shape表 示玻璃效果应用的形状，这里我们传入了一个圆角矩形shape，确保玻璃效果只在这个形状内生效。
                    // 除此之外还有其他参数可以调整玻璃效果，比如颜色、模糊度等，可以根据需要进行配置。通过overlay来调整
                    .overlay {
                        shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.6)
                    }
                    .overlay {
                        shape.fill(.white.opacity(0.8))
                    }
            }
            .clipShape(shape)
    }
}

