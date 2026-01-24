//
//  CalendarPageTypes.swift
//  Done
//
//  日历页面的类型定义和状态枚举
//  这个文件定义了日历页面所需的所有核心数据类型，包括页面模式、时间范围、
//  header 可见性等，供 CalendarPageStateMachine 和 CalendarPageView 使用。

/// ============================================================
/// 页面模式枚举
/// ============================================================
/// 描述日历页面当前的工作模式，决定了 header 样式和 timeline 的交互行为。
/// 两种模式之间可以通过**下拉超过阈值**来切换（由状态机触发）。
enum PageMode {
    /// 预览模式：用户查看日程，只读操作
    /// 视觉表现：Header 显示普通标题，Timeline 以只读卡片形式展示事件，用户无法直接编辑
    /// 交互：下拉可切换到 edit 模式，点击事件打开详情页
    case preview
    
    /// 编辑模式：用户新增或编辑日程
    /// 视觉表现：Header 显示编辑相关按钮，Timeline 以可编辑表单形式展示事件
    /// 交互：下拉可切换回 preview 模式，提供保存/取消操作
    case edit
}

/// ============================================================
/// 时间范围枚举
/// ============================================================
/// 描述 timeline 中显示的日期范围，决定了用户一次看到的日程跨度。
/// 用户可以在页面顶部的控件切换这三种范围。
enum RangeMode {
    /// 单日视图：当天的所有事件（从午夜到午夜）
    /// 适用：查看当天详细日程、小屏幕设备（如 Apple Watch）
    /// 特点：垂直滚动，显示最细致的时间粒度
    case day
    
    /// 三日视图：今天 + 未来两天（共 3 天）的所有事件
    /// 适用：查看近期日程规划，平衡详细信息和总体视图
    /// 特点：可能采用水平分页或竖直堆叠，显示 3 个日期的所有事件
    case threeDay
    
    /// 周视图：当前周（7 天）的所有事件
    /// 适用：周计划概览，长期规划和时间管理
    /// 特点：可能采用网格或列表布局，显示整个星期的事件分布
    case week
}

/// ============================================================
/// Header 可见性枚举
/// ============================================================
/// 描述页面顶部 header（标题栏）是否在屏幕上可见。
/// 这个状态由滚动位置自动控制，用于节省屏幕空间。
enum HeaderVisibility: Equatable {
    /// Header 可见：用户可以看到日期、标题、操作按钮等
    /// 触发时机：滚动位置在顶部附近、用户下拉切换模式时、用户滚回顶部
    case visible
    
    /// Header 隐藏：Header 不显示，timeline 向上扩展占用 header 的空间
    /// 触发时机：用户向下滚动超过 hideSnapDistance 的阈值
    /// 恢复时机：用户滚动回到阈值以上、用户下拉超过展开距离
    case hidden
}

/// ============================================================
/// 日历页面状态结构体
/// ============================================================
/// 封装日历页面的完整状态快照，由 CalendarPageStateMachine 计算和更新。
/// 这是 UI 层（CalendarPageView）观察的主要数据源。
/// 设计特点：不可变模式（Equatable）、包含三个独立的状态维度、有预定义初始状态
struct CalendarPageState: Equatable {
    /// 当前的页面工作模式（.preview 或 .edit）
    /// 由用户下拉手势触发切换
    var pageMode: PageMode
    
    /// 当前 header 的可见性状态（.visible 或 .hidden）
    /// 由滚动位置自动控制
    var headerVisibility: HeaderVisibility
    
    /// 下拉切换的就绪标志
    /// true：用户已经滚回顶部，允许再次触发模式切换
    /// false：用户刚刚触发过切换，需要滚回顶部才能再次切换
    /// 目的：防止过度滚动时多次频繁切换
    /// 逻辑：scrollY >= 0 时设置为 true；触发切换时设置为 false
    var pullToggleReady: Bool

    /// 初始状态常量
    /// 应用启动或页面重置时使用
    /// 初始值：pageMode = .preview（查看模式），headerVisibility = .visible，pullToggleReady = true
    /// 使用示例：@State private var pageState: CalendarPageState = .initial
    static var initial: CalendarPageState {
        CalendarPageState(pageMode: .preview, headerVisibility: .visible, pullToggleReady: true)
    }
    /// 调用示例： CalendarPageState.initial
    /// 这个是用在 CalendarPageView.swift 文件中的 @State 初始化中
    /// 
    /// 这一整个struct的思路是通过判断pageMode, headerVisibility, pullToggleReady
    /// 三个属性来描述日历页面的当前状态，然后组装成一个Calendar。
    /// 
}
