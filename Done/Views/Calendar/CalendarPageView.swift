//
//  CalendarPageView.swift
//  Done
//
//  Entry point for the calendar tab. Retrieves event data from `EventStore`
//  and composes a fixed header (via `GlassCardView`) above a scrolling timeline
//  (`CalendarTimelineView` → `TimelineDayView` + `CalendarLayout` helpers).
//
//  Component Call Graph (View Tree)
//  CalendarPageView
//  - GeometryReader
//    - ZStack(alignment: .top) [ignoresSafeArea(.top)]
//      - timelineScroll (ScrollView + top fade)
//        - CalendarTimelineView(events) [paddingTop = timelineTopInset]
//      - headerCard (fixed overlay)
//        - GlassCardView [paddingTop = headerTopInset]
//
//  The outer container ignores the top safe area so the timeline + fade can reach y=0.
//  Header uses safe-area-aware padding to avoid the status bar.
//  The top edge of the timeline has an optional hold (0 alpha), then feathers (0 -> 1)
//  so content becomes fully visible below.
//
//  Created by opencode and yifan mei on 1/14/26.
//

import SwiftUI

/// Hosts the calendar tab layout and handles shared spacing metrics.
struct CalendarPageView: View {
    @EnvironmentObject private var store: EventStore

    var body: some View {
        GeometryReader { proxy in
            let metrics = Metrics(containerSize: proxy.size, safeAreaTop: proxy.safeAreaInsets.top)

            ZStack(alignment: .top) {
                // Timeline scrolls under the fixed header.
                timelineScroll(metrics: metrics)

                headerCard(metrics: metrics)
                    .allowsHitTesting(false)
            }
            // 这里我修改成了zstack这样可以让时间线滚动视图在顶部延伸到安全区域之外
            .ignoresSafeArea(edges: .top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

private extension CalendarPageView {
    // MARK: - Layout Metrics
    // 这里定义的是一些布局相关的常量和计算属性，方便在视图中使用
    // metrics结构体封装了这些布局参数

    // extension的意思是对CalendarPageView进行扩展，添加私有的布局辅助功能
    // 如果你不懂extension是什么意思，可以把它理解为给已有的类型添加新的功能
    // 比如这里我们给CalendarPageView添加了一个私有的Metrics结构体，用来存储布局相关的数据
    // 如果不使用extension的话，这些布局数据就只能直接写在CalendarPageView的主体里，可能会显得比较杂乱
    struct Metrics {
        let containerSize: CGSize
        // cgsize的含义是：表示一个二维的尺寸，包含宽度和高度两个属性。在这里它表示CalendarPageView可用的整体空间大小。
        let safeAreaTop: CGFloat

        var topCardHeight: CGFloat {
            max(120, containerSize.height * 0.12)
        }

        let horizontalPadding: CGFloat = 16
        let topPadding: CGFloat = 0
        // 这里的topPadding是用来控制玻璃卡片顶部与屏幕顶部之间的间距
        let timelineBottomPadding: CGFloat = 24
        let headerToTimelineSpacing: CGFloat = 0
        // 这个参数是用来控制时间线内容起点与玻璃卡片底部之间的间距
        let timelinepaddingOffset: CGFloat = 16
        // 这个参数是用来调整时间线内容的实际起点位置，确保
        let verticalLift: CGFloat = 24
        // 控制卡片和时间线在视觉上整体向上偏移，同时保持 mask 的起点不变

        let timelineTopFadeHoldHeight: CGFloat = 24
        // 这个参数是用来控制时间线内容顶部的保持透明区域的高度
        let timelineTopFeatherHeight: CGFloat = 48
        // 这个参数是用来控制时间线内容顶部的渐变遮罩效果的高度

        var timelineMaskHeight: CGFloat {
            max(0, timelineTopFadeHoldHeight + timelineTopFeatherHeight)
        }

        /// Hold stop location within the top mask region [0, 1].
        var timelineFadeHoldStop: CGFloat {
            guard timelineMaskHeight > 0 else { return 0 }
            return min(1, max(0, timelineTopFadeHoldHeight / timelineMaskHeight))
        }
        // 这个地方计算的逻辑是：计算在遮罩区域内，保持完全透明的部分占整个遮罩高度的比例
        // 其中min选择1的情况是为了防止timelineTopFadeHoldHeight大于timelineMaskHeight导致比例超过1
        // max中的timelineTopFadeHoldHeight和timelineMaskHeight的区别是：前者是保持透明的高度，后者是整个遮罩的高度
        // 目前这两个均为常量，但如果将来需要动态调整，这样计算会更灵活
        // 如果两个值相等的时候，timelineFadeHoldStop会等于1，表示整个遮罩区域都是保持

        var headerTopInset: CGFloat {
            safeAreaTop + topPadding
        }
        // 这个属性计算了玻璃卡片顶部距离屏幕顶部的实际间距，考虑了安全区域

        var timelineTopInset: CGFloat {
            headerTopInset + topCardHeight + headerToTimelineSpacing - timelinepaddingOffset
        }
        // 这个属性计算了时间线内容顶部距离屏幕顶部的实际间距，确保内容不会被header遮挡
    }

    // MARK: - Composition
    /// Wraps the glass header card and pins it to the top with consistent padding.
    func headerCard(metrics: Metrics) -> some View {
        GlassCardView()
        // GlassCardView是一个自定义的视图组件，表示日历页面顶部的玻璃质感卡片，这个文件在Done/Views/Calendar/Components/GlassCardView.swift中定义
            .frame(height: metrics.topCardHeight)
            .padding(.horizontal, metrics.horizontalPadding)
            .padding(.top, metrics.headerTopInset)
            .offset(y: -metrics.verticalLift)
    }

    /// Embeds the timeline scroll view that pages `TimelineDayView`s via `CalendarTimelineView`.
    func timelineScroll(metrics: Metrics) -> some View {
        ScrollView {
            // scrollview用于实现垂直滚动的时间线视图
            CalendarTimelineView(events: store.events)
                .padding(.top, metrics.timelineTopInset)
                // 这个地方的padding是为了给时间线视图顶部留出空间，以避免内容被顶部的玻璃卡片遮挡
                .padding(.horizontal, metrics.horizontalPadding)
                .padding(.bottom, metrics.timelineBottomPadding)
                .offset(y: -metrics.verticalLift)
        }
        .mask {
            // mask的功能是实现顶部的渐变遮罩效果（hold + feather）
            VStack(spacing: 0) {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0), location: 0),
                        .init(color: .black.opacity(0), location: metrics.timelineFadeHoldStop),
                        .init(color: .black.opacity(1), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: metrics.timelineMaskHeight)

                Rectangle()
                    .fill(.black)
            }
        }
    }
}
