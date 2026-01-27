//
//  CalendarPageComposer.swift
//  Done
//
//  将日历页面的抽象状态转换为具体的 UI 组合选择
//  这个文件负责根据当前的页面状态（state）、滚动位置（scrollY）、
//  布局指标（metrics）等，计算出 header 和 timeline 应该如何展示。
//  
//  核心职责：
//  1. 根据状态计算 header 的样式（normal/expanded）
//  2. 根据滚动位置计算 header 的透明度、缩放、高度等动画参数
//  3. 根据页面模式选择 timeline 的显示模式（preview/edit）
//  4. 根据时间范围模式选择要显示的日期范围

import SwiftUI

/// ============================================================
/// Header 展示参数结构体
/// ============================================================
/// 封装了 header 在视觉上应该如何表现的所有参数。
/// 这些值由 CalendarPageComposer 根据状态和滚动位置计算得出，
/// 然后由 CalendarHeaderView 应用这些参数进行渲染。
/// 
/// 设计目的：将布局计算与 UI 渲染分离，使参数可以被预览和测试。
struct CalendarHeaderPresentation {
    /// Header 的显示高度（像素）
    /// 随着滚动隐藏时从 normalHeaderHeight 或 expandedHeaderHeight 逐渐降低到 0
    /// 范围：[0, max(normalHeaderHeight, expandedHeaderHeight)]2
    let height: CGFloat
    
    /// Header 顶部的安全区域插入（像素）
    /// 考虑了设备的 notch、刘海等凹陷
    /// 隐藏时从 safeAreaTop 逐渐降低到 0
    /// 范围：[0, safeAreaTop]
    let topInset: CGFloat
    
    /// Header 的透明度（不透明度）
    /// 1.0：完全不透明（可见）
    /// 0.0：完全透明（不可见）
    /// 用于淡出/淡入效果
    /// 范围：[0, 1]
    let opacity: CGFloat
    
    /// Header 的缩放比例
    /// 1.0：原始大小
    /// 0.98：缩小到 98% 的大小
    /// 隐藏时轻微缩小，配合透明度变化产生平滑的消失效果
    /// 范围：[0.98, 1.0]
    let scale: CGFloat
}

/// ============================================================
/// 日历页面组合方案结构体
/// ============================================================
/// 聚合了日历页面所有的 UI 组合决策。
/// 这是 CalendarPageComposer.compose() 的返回值，
/// 包含了 UI 层需要的所有信息，用于驱动 CalendarPageView 的渲染。n///
/// 生命周期：
/// CalendarPageState 变化 → CalendarPageComposer.compose() → 
/// CalendarPageComposition 生成 → CalendarPageView 使用 → UI 更新
struct CalendarPageComposition {
    /// Header 的显示模式
    /// .normal：普通模式（对应 preview 页面模式）
    /// .expanded：展开模式（对应 edit 页面模式，显示更多内容）
    let headerMode: CalendarHeaderView.Mode
    
    /// Header 的展示参数（高度、透明度、缩放等）
    /// 包含了所有与 header 可视化相关的参数
    let headerPresentation: CalendarHeaderPresentation
    
    /// Timeline 的活跃模式（用户当前看到的是哪个）
    /// .preview：预览模式（只读）
    /// .edit：编辑模式（可交互）
    /// 虽然两个 timeline 都会被创建（保持状态），但只有活跃的会响应交互
    let activeTimelineMode: PageMode

    /// Timeline 要显示的时间范围
    /// .day：单日
    /// .threeDay：三日
    /// .week：周视图
    /// 由用户在 TimelineHeaderBar 中选择的 rangeMode 决定
    let timelineRange: RangeMode
    
    /// Timeline 的重建键（用于强制刷新）
    /// 格式："timeline-{rangeMode}"，如 "timeline-day"
    /// 当 rangeMode 改变时，使用 .id(timelineRebuildKey) 强制重建 timeline
    /// 目的：避免范围切换时旧 TabView 页面残留导致的布局错误
    let timelineRebuildKey: String
    
    /// Timeline 距离顶部的垂直间距
    /// 计算：safeAreaTop + headerHeight + headerToTimelineSpacing
    /// 确保 timeline 内容不被 header 和安全区遮挡
    /// 在 ScrollView 中用 .padding(.top) 应用此值
    let timelineTopPadding: CGFloat
}

/// ============================================================
/// 日历页面组合器
/// ============================================================
/// 这是一个纯函数库，负责将抽象的状态转换为具体的 UI 组合方案。
/// 没有副作用，所有计算都是确定性的，便于测试和调试。n///
/// 工作流程：
/// 1. 接收当前状态（state）、滚动位置（scrollY）、布局指标（metrics）
/// 2. 根据 state.pageMode 确定 header 模式
/// 3. 根据 scrollY 和 metrics 计算 hideProgress（隐藏进度）
/// 4. 基于 hideProgress 计算 header 的各项动画参数（高度、透明度、缩放等）
/// 5. 根据 state 和 rangeMode 确定 timeline 的显示模式和范围
/// 6. 计算 timeline 的顶部间距
/// 7. 返回完整的 CalendarPageComposition 对象供 UI 层使用
struct CalendarPageComposer {
    /// 根据当前的页面状态和滚动上下文生成完整的组合方案
    /// 
    /// 这个方法是 CalendarPageComposer 的核心，负责将所有状态转换为 UI 可用的参数。
    /// 它在每次滚动时被调用（通过 onScrollGeometryChange），
    /// 因此需要高效且无副作用。n    ///
    /// - Parameters:
    ///   - state: 当前的页面状态（edit/preview 模式、header 可见性等）
    ///   - rangeMode: 用户选择的时间范围（day/threeDay/week）
    ///   - scrollY: 当前的滚动位置（正值表示向下滚动）
    ///   - metrics: 布局相关的所有阈值和常量（由 CalendarPageMetrics 提供）
    /// - Returns: CalendarPageComposition 对象，包含所有 UI 层需要的信息
    static func compose(
        state: CalendarPageState,
        rangeMode: RangeMode,
        scrollY: CGFloat,
        metrics: CalendarPageMetrics
    ) -> CalendarPageComposition {
        let headerMode: CalendarHeaderView.Mode = (state.pageMode == .edit) ? .expanded : .normal
        let hideProgress = hideProgress(
            state: state,
            headerMode: headerMode,
            scrollY: scrollY,
            metrics: metrics
        )

        let headerHeight: CGFloat
        if state.headerVisibility == .visible, headerMode == .expanded {
            headerHeight = metrics.expandedHeaderHeight
        } else {
            headerHeight = lerp(metrics.normalHeaderHeight, 0, hideProgress)
        }

        let topInset = metrics.safeAreaTop * (1 - hideProgress)
        let presentation = CalendarHeaderPresentation(
            height: max(0, headerHeight),
            topInset: max(0, topInset),
            opacity: lerp(1, 0, hideProgress),
            scale: lerp(1, 0.98, hideProgress)
        )

        let timelineTopPadding = metrics.safeAreaTop + headerHeight + metrics.headerToTimelineSpacing

        return CalendarPageComposition(
            headerMode: headerMode,
            headerPresentation: presentation,
            activeTimelineMode: state.pageMode,
            timelineRange: rangeMode,
            timelineRebuildKey: "timeline-\(rangeMode)",
            timelineTopPadding: timelineTopPadding
        )
    }

    /// 计算 header 的隐藏进度（0 到 1 之间）
    /// 
    /// 这个方法决定了 header 应该隐藏到什么程度。
    /// 
    /// 算法：
    /// 1. 如果 header 应该保持可见（visible 且 expanded），返回 0（完全显示）
    /// 2. 否则，根据滚动距离计算线性插值：
    ///    - hideStartDistance：开始隐藏的滚动位置
    ///    - hideSnapDistance：完全隐藏的滚动位置
    ///    - progress = (scrollY - start) / (end - start)，范围 [0, 1]
    /// 
    /// 返回值用途：
    /// - 0.0：header 完全显示
    /// - 0.5：header 处于 50% 隐藏状态
    /// - 1.0：header 完全隐藏
    /// 
    /// - Returns: 隐藏进度，范围 [0, 1]
    private static func hideProgress(
        state: CalendarPageState,
        headerMode: CalendarHeaderView.Mode,
        scrollY: CGFloat,
        metrics: CalendarPageMetrics
    ) -> CGFloat {
        if state.headerVisibility == .visible, headerMode == .expanded {
            return 0
        }

        let y = max(0, scrollY)
        let end = max(metrics.hideSnapDistance, 1)
        let start = clamp(metrics.hideStartDistance, 0, end)
        let t = (y - start) / max(end - start, 1)
        return clamp(t, 0, 1)
    }

}
