//
//  CalendarPageStateMachine.swift
//  Done
//
//  Pure state transitions for CalendarPage scroll interactions.
//  该文件实现了日历页面的状态机，负责根据用户的滚动行为计算状态转换。
//  主要职责：
//  1. 监听滚动位置 (scrollY) 的变化
//  2. 根据预定义的阈值和指标计算下一个状态
//  3. 判断状态转换是否需要动画
//  4. 返回状态转换结果，供 UI 层调用

import SwiftUI

/// 日历页面状态机
/// 这是一个纯状态转换函数库，不依赖任何 UI 框架，便于单元测试和状态复用。
struct CalendarPageStateMachine {
    
    /// 状态转换结果结构体
    /// 包含下一个状态和是否需要动画的信息，供 UI 层根据需要应用动画。
    struct Transition {
        /// 计算出的下一个页面状态
        /// 包含 pageMode（edit/preview）、headerVisibility（显示/隐藏）、pullToggleReady（是否可切换）
        let state: CalendarPageState
        /// 这个CalendarPageState被定义在了 CalendarPageTypes.swift 文件中
        
        /// 是否需要执行动画
        /// true：UI 层应该使用 withAnimation 来更新状态
        /// false：UI 层直接更新状态，无过渡动画
        let shouldAnimate: Bool
        /// 动画包括了 header 的显示/隐藏和平滑切换 edit/preview 模式
        /// 需要动画的场景：
        /// 1. 用户下拉超过阈值切换模式
        /// 2. 用户滚动超过阈值隐藏 header
        /// 3. 用户滚动回到顶部显示 header
        /// 不需要动画的场景：
        /// 1. 用户滚动但未超过任何阈值
        /// 2. 状态未发生变化
    }

    /// 核心状态转换函数
    /// 这个纯函数根据当前状态、滚动位置和布局指标，计算下一个状态。
    /// 返回一个 Transition 结构体，包含新状态和是否需要动画。
    ///
    /// - Parameters:
    ///   - state: 当前的页面状态（edit/preview 模式、header 可见性、切换就绪标志）
    ///   - scrollY: 当前的滚动位置
    ///     正值：向下滚动（内容向上移动）
    ///     0：顶部
    ///     负值：向上滚动（下拉/过度滚动）
    ///   - metrics: 包含所有阈值的布局指标
    ///     expandPullDistance：触发模式切换的下拉距离
    ///     hideSnapDistance：header 开始隐藏的滚动距离
    ///     hideThreshold：隐藏触发的百分比阈值（0-1）
    /// - Returns: Transition 结构体，包含下一个状态和是否需要动画
    static func transition(
        from state: CalendarPageState,
        scrollY: CGFloat,
        metrics: CalendarPageMetrics
    ) -> Transition {
        // 初始化：复制当前状态作为基础，逐步修改需要改变的属性
        var next = state
        var shouldAnimate = false

        // ============================================================
        // 第一步：处理下拉切换就绪标志的重置
        // ============================================================
        // 当滚动回到顶部（scrollY >= 0）时，标记用户可以再次触发模式切换
        // 这确保用户必须先回到顶部才能再次下拉切换，避免频繁切换
        if scrollY >= 0 {
            next.pullToggleReady = true
        }

        // ============================================================
        // 第二步：处理下拉切换 edit/preview 模式的逻辑
        // ============================================================
        // 当满足两个条件时触发模式切换：
        // 1. scrollY <= -metrics.expandPullDistance：用户下拉超过阈值距离
        // 2. state.pullToggleReady：用户之前已经回到顶部（切换就绪）
        // 
        // 如果条件满足，执行以下操作：
        if scrollY <= -metrics.expandPullDistance, state.pullToggleReady {
            // 在 edit 和 preview 模式之间切换
            // .edit 模式：用户可以编辑日程
            // .preview 模式：用户查看日程
            next.pageMode = (state.pageMode == .edit) ? .preview : .edit
            
            // 切换时强制显示 header，确保用户看到新模式的标题
            next.headerVisibility = .visible
            
            // 禁用切换，直到用户滚回顶部并再次设置 pullToggleReady = true
            // 这防止过度滚动时多次触发切换
            next.pullToggleReady = false
            
            // 标记需要动画：模式切换是用户可见的明显变化，需要平滑过渡
            shouldAnimate = true
            
            // 立即返回，不再处理 header 隐藏逻辑
            return Transition(state: next, shouldAnimate: shouldAnimate)
        }

        // ============================================================
        // 第三步：处理 header 的自动显示/隐藏逻辑
        // ============================================================
        // 根据滚动位置自动控制 header 的可见性，节省屏幕空间
        
        // 计算 header 隐藏的触发阈值
        // hideSnapDistance：完整的隐藏距离范围
        // hideThreshold（0-1）：在这个距离范围内的百分比位置触发隐藏
        // 例：hideSnapDistance=200, hideThreshold=0.5 → cutoff=100
        let cutoff = metrics.hideSnapDistance * clamp(metrics.hideThreshold, 0, 1)
        /// cutoff的作用是作为一个滚动位置的临界点，用来决定日历页面的 header 应该是显示还是隐藏。
        /// 具体的，cutoff 是一个基于 hideSnapDistance 和 hideThreshold 计算出的值，表示 header 开始隐藏的滚动位置。
        /// 当用户滚动超过这个位置时，header 就会被隐藏；当用户滚动回到这个位置以下时，header 就会重新显示.
        /// 这个cutoff是用来判断用户滚动位置是否超过了预设的阈值，从而决定header的显示状态。
        ///     如果用户滚动位置 scrollY 大于等于 cutoff，说明用户已经滚动过了隐藏 header 的阈值，header 应该被隐藏。
        ///     如果用户滚动位置 scrollY 小于 cutoff，说明用户还没有滚动到隐藏 header 的阈值，header 应该保持显示状态。


        // 根据滚动位置判断 header 应该是可见还是隐藏
        // scrollY >= cutoff：滚动超过阈值 → 隐藏 header（更多内容）
        // scrollY < cutoff：滚动未超过阈值 → 显示 header
        let targetVisibility: HeaderVisibility = (scrollY >= cutoff) ? .hidden : .visible
        
        // 只在状态真正改变时才触发动画和设置标志
        // 这避免了多次调用同一函数时的无效状态更新
        if targetVisibility != state.headerVisibility {
            next.headerVisibility = targetVisibility // header 可见性发生变化
            shouldAnimate = true  // header 的显示/隐藏需要淡出/淡入动画
        }

        // 返回计算出的状态转换结果
        return Transition(state: next, shouldAnimate: shouldAnimate)
    }

}
