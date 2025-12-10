# 项目结构说明

## 目录结构

```
Done/
├── Done.xcodeproj/              # Xcode 项目文件
├── Done/                        # iOS App
│   ├── DoneApp.swift           # iOS App 入口
│   ├── ContentView.swift       # iOS 主界面 (Tab View)
│   ├── Models/                 # 数据模型（共享）
│   │   ├── ActivityTemplate.swift    # 活动模板
│   │   ├── TimeEntry.swift          # 时间记录
│   │   └── SyncMessage.swift        # 同步消息
│   ├── Services/               # 服务层
│   │   ├── DataManager.swift        # 数据管理器
│   │   ├── PhoneConnectivityManager.swift  # Watch 连接管理
│   │   └── GoogleCalendarService.swift     # Google Calendar API
│   ├── Views/                  # UI 视图
│   │   ├── TemplateManagementView.swift   # 模板管理
│   │   ├── TimeEntriesView.swift         # 历史记录
│   │   ├── AnalyticsView.swift           # 数据分析
│   │   └── SettingsView.swift            # 设置
│   └── Assets.xcassets/        # 资源文件
│
├── Done Watch App/             # WatchOS App
│   ├── DoneApp.swift          # Watch App 入口
│   ├── ContentView.swift      # Watch 主界面 (按钮网格 + 计时器)
│   ├── Models/                # 数据模型（共享）
│   │   ├── ActivityTemplate.swift
│   │   ├── TimeEntry.swift
│   │   └── SyncMessage.swift
│   ├── Services/              # 服务层
│   │   ├── DataManager.swift           # 数据管理器
│   │   └── WatchConnectivityManager.swift  # iPhone 连接管理
│   └── Assets.xcassets/       # 资源文件
│
├── DoneTests/                 # iOS 单元测试
├── DoneUITests/              # iOS UI 测试
├── Done Watch AppTests/       # Watch 单元测试
├── Done Watch AppUITests/     # Watch UI 测试
│
├── README.md                  # 项目说明
├── SETUP.md                   # 快速设置指南
└── PROJECT_STRUCTURE.md       # 本文件
```

## 架构设计

### 数据流

```
┌─────────────────┐         ┌─────────────────┐
│  Apple Watch    │◄───────►│   iPhone        │
│                 │  WC※    │                 │
│ ┌─────────────┐ │         │ ┌─────────────┐ │
│ │ Quick       │ │         │ │ Template    │ │
│ │ Buttons     │ │         │ │ Manager     │ │
│ └─────────────┘ │         │ └─────────────┘ │
│ ┌─────────────┐ │         │ ┌─────────────┐ │
│ │ Timer       │ │         │ │ Analytics   │ │
│ └─────────────┘ │         │ └─────────────┘ │
│ ┌─────────────┐ │         │ ┌─────────────┐ │
│ │ DataManager │ │         │ │ DataManager │ │
│ └─────────────┘ │         │ └─────────────┘ │
└─────────────────┘         └────────┬────────┘
                                     │ OAuth 2.0
                                     ▼
                            ┌─────────────────┐
                            │ Google Calendar │
                            └─────────────────┘

※ WC = Watch Connectivity
```

### 数据模型关系

```
ActivityTemplate (1) ──┐
                       │
                       │ templateId
                       │
                       └──► TimeEntry (N)
                              │
                              │ calendarEventId
                              ▼
                       Google Calendar Event
```

## 核心组件说明

### 1. 数据模型 (Models/)

#### ActivityTemplate
- 表示一个活动类型（如"工作"、"会议"）
- 包含名称、颜色、图标、排序
- 在 iPhone 上管理，同步到 Watch

#### TimeEntry
- 表示一次时间记录
- 包含开始时间、结束时间、关联的模板
- 从 Watch 创建，同步到 iPhone，然后同步到 Google Calendar

#### SyncMessage
- Watch Connectivity 通信协议
- 定义不同类型的同步消息

### 2. 服务层 (Services/)

#### DataManager
- 单例模式，管理所有本地数据
- 使用 UserDefaults 持久化
- 提供数据的 CRUD 操作
- 在 iOS 和 Watch 上各有一个实例

#### PhoneConnectivityManager (iOS)
- 管理与 Apple Watch 的连接
- 接收来自 Watch 的时间记录
- 发送模板更新到 Watch

#### WatchConnectivityManager (Watch)
- 管理与 iPhone 的连接
- 发送时间记录到 iPhone
- 接收来自 iPhone 的模板更新

#### GoogleCalendarService (iOS only)
- OAuth 2.0 认证流程
- Google Calendar API 调用
- 自动同步时间记录

### 3. 视图层 (Views/)

#### TemplateManagementView
- 显示所有活动模板
- 支持添加、编辑、删除、重排序
- 使用 TemplateEditView 进行编辑

#### TimeEntriesView
- 显示所有时间记录
- 按日期分组
- 支持筛选（今天、本周、本月、全部）
- 显示同步状态

#### AnalyticsView
- 使用 Charts 框架显示饼图
- 活动时间占比统计
- 支持周/月/年视图

#### SettingsView
- Google Calendar 连接管理
- 显示用户邮箱
- 登录/登出功能

## Watch App 界面

### ContentView (主界面)
- 根据是否有活动计时显示不同视图
- ActivityGridView: 2x3 网格显示快速按钮
- ActiveTimerView: 显示当前计时器

### ActivityGridView
- 显示所有活动模板的按钮
- 点击开始追踪

### ActiveTimerView
- 显示活动名称
- 实时更新的计时器 (HH:MM:SS)
- 停止按钮

## 数据同步机制

### 模板同步 (iPhone → Watch)
1. 用户在 iPhone 上编辑模板
2. DataManager.saveTemplates() 调用
3. PhoneConnectivityManager.syncTemplates() 发送消息
4. WatchConnectivityManager 接收并更新 Watch 数据

### 时间记录同步 (Watch → iPhone → Google)
1. 用户在 Watch 上停止计时
2. DataManager.stopTracking() 创建 TimeEntry
3. WatchConnectivityManager.sendTimeEntry() 发送到 iPhone
4. PhoneConnectivityManager 接收并添加到数据
5. DataManager.addTimeEntry() 触发 Google 同步
6. GoogleCalendarService.syncTimeEntry() 上传到 Calendar

## 状态管理

使用 SwiftUI 的 `@StateObject` 和 `@Published`:

- DataManager: `@Published var templates` 和 `timeEntries`
- GoogleCalendarService: `@Published var isAuthenticated`

视图自动响应数据变化。

## 持久化策略

- **UserDefaults**: 存储模板和时间记录
- **未来**: 可以迁移到 Core Data 或 SwiftData
- **同步**: 通过 Google Calendar 作为云端备份

## 安全性

- OAuth 2.0 with PKCE 流程
- 访问令牌存储在 UserDefaults（生产环境应使用 Keychain）
- 自动刷新过期令牌
- 不存储密码

## 性能优化

- 使用 `LazyVGrid` 和 `LazyVStack` 延迟加载
- 数据按需加载和过滤
- Watch 上使用轻量级 UI
- 后台同步不阻塞 UI

## 扩展点

### 添加新的活动类型
1. 在 `ActivityTemplate.defaultTemplates` 添加预设
2. 或通过 iPhone UI 添加

### 更改数据存储
1. 替换 DataManager 中的 UserDefaults 调用
2. 实现 Core Data 或 SwiftData

### 添加其他日历服务
1. 创建新的 Service（如 OutlookCalendarService）
2. 遵循相同的同步模式
3. 在 SettingsView 中添加选项

## 测试策略

- 单元测试: 测试 DataManager 的 CRUD 操作
- 集成测试: 测试 Watch Connectivity 同步
- UI 测试: 测试关键用户流程
- 手动测试: Google OAuth 流程

## 常见问题

### 为什么使用 UserDefaults 而不是 Core Data?
- 简单易用，适合小规模数据
- 支持 Watch Connectivity 传输
- 未来可以轻松迁移

### 为什么不使用 CloudKit 同步?
- Google Calendar 已经提供了云端存储
- 减少复杂性
- 可以作为未来功能添加

### 如何处理冲突?
- Watch 是唯一的时间记录创建源
- iPhone 是唯一的模板编辑源
- Google Calendar 只用于备份，不会写回

## 下一步优化

1. **性能**: 添加数据分页和虚拟滚动
2. **安全**: 将令牌移到 Keychain
3. **功能**: 添加编辑时间记录
4. **体验**: 添加 Complications 和 Widgets
5. **数据**: 迁移到 SwiftData (iOS 17+)
