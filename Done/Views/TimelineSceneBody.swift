//
//  TimelineSceneBody.swift
//  Done
//
//  Body scroll content for TimelineScene.
//

import SwiftUI

/// 本文件按“外部滚动容器 → 时间轴 + 日期列 → 每列内事件块”顺序构建视图层级：
/// 1. 用竖直 `ScrollView` 包裹整个内容，兼容 safe area。
/// 2. 左侧展示固定时间轴，右侧用横向 `ScrollView` 分列天数，保持 `scrollCenterDate` 同步。
/// 3. 每列叠加网格与事件块，并将事件限制在当前日期范围，支持拖拽与变更回调。
/// 这种设计可保证时间轴始终可见，同时让多天内容借助懒加载列和 Canvas 背景保持性能。
struct TimelineSceneBody: View {
    @ObservedObject var viewModel: TimelineViewModel // 提供可渲染的日期范围等数据
    @ObservedObject var eventProvider: TimelineEventProvider // 提供每天的时间条目
    let dataManager: DataManager // 用于更新拖动后事件
    @Binding var scrollCenterDate: Date? // 记录垂直滚动位置的目标日期
    let isMagnifying: Bool // 是否在缩放状态，影响滚动行为
    @Binding var isEventDragging: Bool // 拖动事件时禁用滚动
    let hourHeight: CGFloat // 每小时行的高度
    let timeAxisWidth: CGFloat // 左侧时间轴宽度
    let contentTopInset: CGFloat // 内容顶部留白

    private var totalHeight: CGFloat { 24 * hourHeight } // 一天的总高度

    // 整个视图的主内容滚动区域，包含时间轴与事件列
    var body: some View {
        /**
         竖直滚动容器，包裹完整一天的内容。
         顶部的透明占位用于填充 safe area。
         */
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 0) {
                Color.clear
                    .frame(height: contentTopInset) // 顶部留白用于内容对齐

                GeometryReader { proxy in
                    let contentWidth = max(0, proxy.size.width - timeAxisWidth) // 横向内容的可用宽度
                    HStack(spacing: 0) {
                        TimelineSceneTimeAxis(hourHeight: hourHeight)
                            .frame(width: timeAxisWidth, alignment: .trailing)

                        // 列表内容放在横向滚动区域中，配合时间轴使用
                        timelineColumns(contentWidth: contentWidth)
                    }
                    .frame(height: totalHeight, alignment: .top)
                }
                .frame(height: totalHeight)
            }
        }
        .scrollDisabled(isEventDragging)
    }

    /// 构建多个日期列，通过横向滚动展示
    /**
     横向滚动的日期列集合，每列对应一个待渲染的日期。
     通过 `scrollCenterDate` 绑定保持滚动同步。
     */
    private func timelineColumns(contentWidth: CGFloat) -> some View {
        let columnWidth = contentWidth / CGFloat(max(1, viewModel.dayCount))
        // 每一天占据的列宽
        let scrollPositionBinding = Binding<Date?>(
            get: { scrollCenterDate },
            set: { newValue in
                guard !isMagnifying, !isEventDragging else { return } // 放大或拖动中禁止更新
                scrollCenterDate = newValue // 更新滚动目标日期
            }
        )
        return ScrollView(.horizontal, showsIndicators: true) {
            LazyHStack(spacing: 0) {
                ForEach(viewModel.renderDates, id: \.self) { date in
                    timelineColumn(date: date, width: columnWidth)
                        .id(date)
                }
            }
            .scrollTargetLayout()
            .frame(height: totalHeight, alignment: .top)
        }
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: scrollPositionBinding, anchor: .center) // 居中目标日期，支持滚动同步
        .scrollDisabled(isEventDragging)
        .frame(width: contentWidth, height: totalHeight, alignment: .leading)
    }

    /// 每一天的列，绘制背景网格与事件块
    /**
     单个日期列，包含背景网格与当天的事件块。
     通过 `ZStack` 叠加网格与事件内容。
     */
    private func timelineColumn(date: Date, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            TimelineSceneGrid(hourHeight: hourHeight)

            eventBlocks(for: date, width: width)
        }
        .frame(width: width, height: totalHeight)
    }

    // MARK: Event Blocks
    /// 处理每个事件在当前日期列中的展示位置与拖拽行为
    /**
     负责渲染给定日期的每个事件，裁剪到当天范围并接收拖拽回调。
     */
    private func eventBlocks(for date: Date, width: CGFloat) -> some View {
        let entries = eventProvider.entriesForDate(date) // 当前列需要渲染的事件
        return ZStack(alignment: .topLeading) {
            ForEach(entries) { entry in
                let dayStart = Calendar.current.startOfDay(for: date) // 列开始的时间
                let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? date // 列结束的时间
                let entryEnd = entry.endTime ?? Date() // 事件结束时间，未结束取当前
                let start = max(entry.startTime, dayStart) // 限制在本列范围内
                let end = min(entryEnd, dayEnd) // 限制在本列范围内
                if end > start {
                    TimelineEventBlockView(
                        entry: entry,
                        renderStart: start,
                        renderEnd: end,
                        hourHeight: hourHeight,
                        availableWidth: width,
                        columnWidth: width,
                        showsLabels: viewModel.dayCount == 1,
                        type: eventProvider.type(for: entry),
                        onDragStateChanged: { isDragging in
                            isEventDragging = isDragging
                        },
                        onMove: { updatedEntry in
                            dataManager.updateTimeEntry(updatedEntry)
                        }
                    )
                    // 每个事件块使用内部时间转换计算位置与拖拽结果
                }
            }
        }
    }
}

/**
 左侧时间轴，仅显示 0-23 点的标签，跟随 `hourHeight` 调整。
 */
private struct TimelineSceneTimeAxis: View {
    let hourHeight: CGFloat

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text(String(format: "%d", hour)) // 时刻文本
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(height: hourHeight, alignment: .center)
            }
        }
        // 显示每小时的刻度，跟随主视图的 hourHeight 调整
        .padding(.trailing, 4)
    }
}

/**
 背景网格，使用 Canvas 绘制每小时的虚线，提供时间参考。
 */
private struct TimelineSceneGrid: View {
    let hourHeight: CGFloat

    private var totalHeight: CGFloat { 24 * hourHeight }

    var body: some View {
        // 用 Canvas 写线，表示每小时的分割线
        Canvas { context, size in // 手动绘制每小时分割线
            let centerOffset = hourHeight / 2
            for hour in 0..<24 {
                let y = CGFloat(hour) * hourHeight + centerOffset
                let path = Path { p in
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(
                    path,
                    with: .color(.gray.opacity(0.3)),
                    style: StrokeStyle(lineWidth: 0.5, dash: [4, 4])
                )
            }
        }
        .frame(height: totalHeight)
    }
}
