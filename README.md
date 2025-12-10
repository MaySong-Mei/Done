# Done - Time Tracking for Apple Watch & iOS

一个简单的时间追踪应用，支持 Apple Watch 快速记录和 iOS 端分析，并自动同步到 Google Calendar。

## 功能特点

### Apple Watch
- **快速按钮**: 通过预设的活动按钮快速开始/停止时间追踪
- **实时计时器**: 显示当前正在进行的活动和已用时间
- **本地存储**: 所有记录本地保存，确保数据安全

### iPhone
- **模板管理**: 自定义快速按钮模板（名称、颜色、图标）
- **历史记录**: 查看所有时间记录，支持按日期筛选
- **可视化分析**:
  - 饼图显示时间分配
  - 活动占比统计
  - 支持周/月/年视图
- **Google Calendar 集成**:
  - OAuth 2.0 安全认证
  - 自动同步时间记录到 Google Calendar
- **Watch 同步**: 自动同步模板到 Apple Watch

## 设置指南

### 1. Xcode 项目配置

在 Xcode 中打开项目后，需要将以下文件添加到对应的 Target：

#### Watch App Target
将以下文件添加到 "Done Watch App" target：
- `Done Watch App/Models/ActivityTemplate.swift`
- `Done Watch App/Models/TimeEntry.swift`
- `Done Watch App/Models/SyncMessage.swift`
- `Done Watch App/Services/DataManager.swift`
- `Done Watch App/Services/WatchConnectivityManager.swift`
- `Done Watch App/ContentView.swift`

#### iOS App Target
将以下文件添加到 "Done" target：
- `Done/Models/ActivityTemplate.swift`
- `Done/Models/TimeEntry.swift`
- `Done/Models/SyncMessage.swift`
- `Done/Services/DataManager.swift`
- `Done/Services/PhoneConnectivityManager.swift`
- `Done/Services/GoogleCalendarService.swift`
- `Done/Views/TemplateManagementView.swift`
- `Done/Views/TimeEntriesView.swift`
- `Done/Views/AnalyticsView.swift`
- `Done/Views/SettingsView.swift`
- `Done/ContentView.swift`

### 2. Google OAuth 配置

#### 创建 Google Cloud 项目

1. 访问 [Google Cloud Console](https://console.cloud.google.com/)
2. 创建新项目或选择现有项目
3. 启用 **Google Calendar API**:
   - 导航到 "APIs & Services" > "Library"
   - 搜索 "Google Calendar API"
   - 点击 "Enable"

#### 配置 OAuth 2.0

1. 进入 "APIs & Services" > "Credentials"
2. 点击 "Create Credentials" > "OAuth client ID"
3. 选择 "iOS" 作为应用类型
4. 输入你的应用 Bundle ID（例如：`com.yourcompany.Done`）
5. 下载配置文件或复制 Client ID

#### 更新代码

在 `GoogleCalendarService.swift` 中更新以下配置：

```swift
private let clientID = "YOUR_GOOGLE_CLIENT_ID" // 替换为你的 Client ID
private let redirectURI = "com.googleusercontent.apps.YOUR_CLIENT_ID:/oauth2redirect" // 替换为你的 redirect URI
```

#### Info.plist 配置

在 iOS app 的 `Info.plist` 中添加 URL Scheme：

```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>com.googleusercontent.apps.YOUR_CLIENT_ID</string>
        </array>
    </dict>
</array>
```

### 3. App Groups 配置（可选，用于共享数据）

如果需要在 iOS 和 Watch 之间共享 UserDefaults：

1. 在 Xcode 中选择 iOS target
2. 进入 "Signing & Capabilities"
3. 添加 "App Groups" capability
4. 创建一个新的 App Group（例如：`group.com.yourcompany.Done`）
5. 对 Watch App target 重复相同步骤
6. 在代码中使用 `UserDefaults(suiteName: "group.com.yourcompany.Done")`

## 使用方法

### 首次使用

1. 在 iPhone 上打开 Done app
2. 进入 "Settings" 标签
3. 点击 "Connect Google Calendar" 并完成授权
4. 在 "Templates" 标签中查看或编辑活动模板
5. 在 Apple Watch 上打开 Done app，模板会自动同步

### 记录时间

1. 在 Apple Watch 上打开 Done
2. 点击想要追踪的活动按钮
3. 计时器开始运行
4. 完成后点击 "Stop" 按钮
5. 时间记录自动保存并同步到 iPhone 和 Google Calendar

### 查看分析

1. 在 iPhone 上打开 Done
2. 进入 "Analytics" 标签
3. 选择时间范围（周/月/年）
4. 查看饼图和详细统计

## 技术栈

- **SwiftUI**: 用户界面
- **Watch Connectivity**: iOS 和 WatchOS 数据同步
- **Google Calendar API v3**: 日历事件同步
- **OAuth 2.0 with PKCE**: 安全认证
- **CryptoKit**: 加密操作
- **Charts**: iOS 16+ 原生图表

## 数据结构

### ActivityTemplate
```swift
struct ActivityTemplate {
    let id: UUID
    var name: String
    var colorHex: String
    var icon: String
    var order: Int
}
```

### TimeEntry
```swift
struct TimeEntry {
    let id: UUID
    let templateId: UUID
    var templateName: String
    var startTime: Date
    var endTime: Date?
    var colorHex: String
    var syncedToCalendar: Bool
    var calendarEventId: String?
}
```

## 隐私和数据

- 所有数据本地存储在设备上
- Google Calendar 同步需要用户明确授权
- 不收集任何分析数据
- 可以随时断开 Google 连接

## 后续改进建议

- [ ] 支持编辑已记录的时间条目
- [ ] 添加时间目标和提醒
- [ ] 支持导出 CSV 报告
- [ ] 添加 Complications 支持
- [ ] 支持 iCloud 同步
- [ ] 添加 Siri Shortcuts
- [ ] 支持深色模式优化

## 故障排除

### Google Calendar 同步失败

1. 检查网络连接
2. 确认 Google Calendar API 已启用
3. 验证 OAuth Client ID 配置正确
4. 尝试重新登录 Google 账号

### Watch 和 iPhone 不同步

1. 确保设备已配对
2. 检查蓝牙连接
3. 重启两个设备上的 app
4. 确认 Watch Connectivity 设置正确

## License

MIT License

## 联系方式

如有问题或建议，请提交 Issue。
