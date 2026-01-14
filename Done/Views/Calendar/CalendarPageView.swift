//
//  CalendarPageView.swift
//  Done
//
//  Entry point for the calendar tab. Retrieves event data from `EventStore`
//  and composes the glass header (via `GlassCardView`) above the paged timeline
//  (`CalendarTimelineView` → `TimelineDayView` + `CalendarLayout` helpers).
//  This file orchestrates layout helpers (geometry metrics) and keeps the page
//  structure stable while allowing the detailed timeline implementation to live
//  in the component files.
//
//  Created by opencode and yifan mei on 1/14/26.
//

import SwiftUI

/// Hosts the calendar tab layout and handles shared spacing metrics.
struct CalendarPageView: View {
    @EnvironmentObject private var store: EventStore

    var body: some View {
        GeometryReader { proxy in
            let metrics = Metrics(containerSize: proxy.size)
            // 这里读取了store中的events，可以触发视图刷新
            // metrics的定义在下面的private extension中

            VStack(spacing: metrics.verticalSpacing) {
                headerCard(metrics: metrics)
                timelineScroll(metrics: metrics)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            //这里的frame设置确保VStack占满整个可用空间，从而使得headerCard和timelineScroll正确布局
            //具体来说frame的用法是：
            //  1. maxWidth: .infinity 让VStack在水平方向上尽可能扩展，占满父视图的宽度
            //  2. maxHeight: .infinity 让VStack在垂直方向上尽可能扩展，占满父视图的高度
            //  3. alignment: .top 确保VStack的内容从顶部开始布局
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
        let verticalSpacing: CGFloat = 16

        var topCardHeight: CGFloat {
            max(120, containerSize.height * 0.12)
        }

        let horizontalPadding: CGFloat = 16
        let topPadding: CGFloat = 16
        let timelineBottomPadding: CGFloat = 24
    }

    // MARK: - Composition
    /// Wraps the glass header card and pins it to the top with consistent padding.
    func headerCard(metrics: Metrics) -> some View {
        GlassCardView()
        // GlassCardView是一个自定义的视图组件，表示日历页面顶部的玻璃质感卡片，这个文件在Done/Views/Calendar/Components/GlassCardView.swift中定义
            .frame(height: metrics.topCardHeight)
            .padding(.horizontal, metrics.horizontalPadding)
            .padding(.top, metrics.topPadding)
    }

    /// Embeds the timeline scroll view that pages `TimelineDayView`s via `CalendarTimelineView`.
    func timelineScroll(metrics: Metrics) -> some View {
        ScrollView {
            // scrollview用于实现垂直滚动的时间线视图
            CalendarTimelineView(events: store.events)
                .padding(.horizontal, metrics.horizontalPadding)
                .padding(.bottom, metrics.timelineBottomPadding)
        }
    }
}
