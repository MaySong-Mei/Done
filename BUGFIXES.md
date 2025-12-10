# Bug 修复记录

## 2025-12-10 编译错误和警告修复

### 修复的编译错误

#### 1. Array.move() 方法不可用

**问题：**
`DataManager.reorderTemplates()` 中使用的 `templates.move(fromOffsets:toOffset:)` 方法不可用。

**原因：**
该方法在 Swift 5.5+ (iOS 15+) 中引入，但可能由于编译器或部署目标的原因不可用。

**修复：**
手动实现数组重新排序逻辑：

```swift
func reorderTemplates(from source: IndexSet, to destination: Int) {
    var reordered = templates

    // 收集要移动的元素
    var movedItems: [ActivityTemplate] = []
    for index in source.sorted().reversed() {
        movedItems.insert(reordered.remove(at: index), at: 0)
    }

    // 计算插入位置
    let insertIndex = destination > (source.first ?? 0) ? destination - source.count : destination

    // 插入到新位置
    reordered.insert(contentsOf: movedItems, at: insertIndex)

    // 更新数组和 order
    templates = reordered
    for (index, var template) in templates.enumerated() {
        template.order = index
        templates[index] = template
    }

    saveTemplates()
}
```

**文件：**
- ✅ `Done/Services/DataManager.swift` - 手动实现重新排序

#### 2. ObservableObject 协议错误

**问题：**
- `GoogleCalendarService` 不符合 `ObservableObject` 协议
- `PhoneConnectivityManager` 不符合 `ObservableObject` 协议
- `WatchConnectivityManager` 不符合 `ObservableObject` 协议

**原因：**
缺少 `Combine` 框架导入，`ObservableObject` 协议在 Combine 中定义。

**修复：**
在以下文件中添加 `import Combine`：
- `Done/Services/GoogleCalendarService.swift`
- `Done/Services/PhoneConnectivityManager.swift`
- `Done Watch App/Services/WatchConnectivityManager.swift`

```swift
import Foundation
import Combine  // 添加此行
```

#### 2. UIColor 跨平台兼容性问题

**问题：**
在 `ActivityTemplate.swift` 中使用 `UIColor`，但 watchOS 不支持 `UIColor`。

**原因：**
watchOS 使用 `WatchKit` 而不是 `UIKit`。

**修复：**
使用条件编译：

```swift
#if os(iOS)
import UIKit
#endif

// ...

func toHex() -> String? {
    #if os(iOS)
    // iOS 实现
    guard let components = UIColor(self).cgColor.components, components.count >= 3 else {
        return nil
    }
    let r = Float(components[0])
    let g = Float(components[1])
    let b = Float(components[2])
    return String(format: "#%02lX%02lX%02lX", lroundf(r * 255), lroundf(g * 255), lroundf(b * 255))
    #else
    // watchOS 返回 nil（不需要 hex 转换）
    return nil
    #endif
}
```

**影响：**
- iOS 版本正常工作
- watchOS 版本中 `toHex()` 返回 nil，但不会导致崩溃
- watchOS 中不需要这个功能，因为只显示预定义的颜色

### 修复的编译警告

#### 4. ASPresentationAnchor 初始化器弃用

**警告：**
`'init()' was deprecated in iOS 26.0`

**修复：**
更新 `presentationAnchor(for:)` 返回实际窗口：

```swift
nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let window = windowScene.windows.first else {
        return ASPresentationAnchor()
    }
    return window
}
```

**文件：**
- ✅ `Done/Services/GoogleCalendarService.swift` - 添加 UIKit 导入，更新方法

#### 5. Main Actor 隔离警告

**警告：**
`Call to main actor-isolated static method 'fromDictionary' in a synchronous nonisolated context`

**修复：**
显式标记方法为 `nonisolated`：

```swift
nonisolated static func fromDictionary(_ dict: [String: Any]) -> SyncMessage? {
    // ...
}
```

**文件：**
- ✅ `Done/Models/SyncMessage.swift`
- ✅ `Done Watch App/Models/SyncMessage.swift`

#### 6. 未使用变量警告

**警告：**
`Value 'existing' was defined but never used`

**修复：**
使用 `!= nil` 代替 `if let`：

```swift
if activeEntry != nil {
    stopTracking()
}
```

**文件：**
- ✅ `Done Watch App/Services/DataManager.swift`

### 修复的文件列表

#### 编译错误修复：
1. ✅ `Done/Services/DataManager.swift` - 手动实现数组重新排序
2. ✅ `Done/Services/GoogleCalendarService.swift` - 添加 Combine 导入
3. ✅ `Done/Services/PhoneConnectivityManager.swift` - 添加 Combine 导入
4. ✅ `Done Watch App/Services/WatchConnectivityManager.swift` - 添加 Combine 导入
5. ✅ `Done/Models/ActivityTemplate.swift` - 添加条件编译
6. ✅ `Done Watch App/Models/ActivityTemplate.swift` - 添加条件编译

#### 警告修复：
7. ✅ `Done/Services/GoogleCalendarService.swift` - 添加 UIKit，更新 presentationAnchor
8. ✅ `Done/Models/SyncMessage.swift` - 标记 fromDictionary 为 nonisolated
9. ✅ `Done Watch App/Models/SyncMessage.swift` - 标记 fromDictionary 为 nonisolated
10. ✅ `Done Watch App/Services/DataManager.swift` - 修复未使用变量

### 验证步骤

运行以下命令检查编译错误：

```bash
# 在 Xcode 中
# 1. 选择 "Done" scheme
# 2. Product > Build (⌘B)
# 3. 选择 "Done Watch App" scheme
# 4. Product > Build (⌘B)
```

### 剩余问题

如果还有编译错误，可能的原因：

1. **文件未添加到 Target**
   - 检查每个文件的 Target Membership
   - 确保正确的文件添加到正确的 target

2. **Deployment Target 版本**
   - iOS: 需要至少 16.0（使用了 Charts 框架）
   - watchOS: 需要至少 9.0

3. **缺少框架**
   - 确保所有必需的框架都已链接
   - Combine, SwiftUI, WatchConnectivity, AuthenticationServices

### 后续优化建议

1. **Watch 端的颜色转换**
   - 如果需要在 watchOS 上实现 `toHex()`，可以使用 Core Graphics
   - 或者完全移除这个功能，因为 watchOS 不需要

2. **共享代码**
   - 考虑创建一个 Shared Framework
   - 避免在两个 target 中重复代码

3. **错误处理**
   - 添加更多的错误日志
   - 使用 `os_log` 代替 `print`

## 检查清单

编译前确认：

- [ ] 所有 Swift 文件已添加到正确的 target
- [ ] iOS Deployment Target >= 16.0
- [ ] watchOS Deployment Target >= 9.0
- [ ] 所有必需的框架已导入
- [ ] Google OAuth Client ID 已配置（运行时需要）
- [ ] Info.plist 已配置 URL Scheme（运行时需要）

## 已知限制

1. **watchOS 的 toHex() 方法**
   - 当前返回 nil
   - 不影响功能，因为 watchOS 只使用预定义的颜色

2. **OAuth 只在 iOS 上**
   - Google 认证只能在 iPhone 上完成
   - Watch 通过 Watch Connectivity 接收数据

3. **UserDefaults 存储**
   - 当前使用独立的 UserDefaults
   - 建议使用 App Groups 实现共享存储

## 测试建议

### 单元测试
```swift
// DataManager 测试
func testTemplateCreation()
func testTimeEntryTracking()
func testDataPersistence()

// Sync 测试
func testWatchConnectivity()
func testGoogleCalendarSync()
```

### 集成测试
1. iPhone 创建模板 → Watch 显示
2. Watch 记录时间 → iPhone 显示
3. iPhone 同步 → Google Calendar 显示

## 参考资源

- [Combine Framework](https://developer.apple.com/documentation/combine)
- [Watch Connectivity](https://developer.apple.com/documentation/watchconnectivity)
- [Cross-Platform SwiftUI](https://developer.apple.com/documentation/swiftui/bringing-multiple-windows-to-your-swiftui-app)
