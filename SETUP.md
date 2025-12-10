# 快速设置清单

## ✅ 必须完成的步骤

### 1. 在 Xcode 中添加文件到 Target

**Watch App 需要的文件：**
- [ ] `Done Watch App/Models/*.swift` (3 个文件)
- [ ] `Done Watch App/Services/*.swift` (2 个文件)
- [ ] `Done Watch App/ContentView.swift`

**iOS App 需要的文件：**
- [ ] `Done/Models/*.swift` (3 个文件)
- [ ] `Done/Services/*.swift` (3 个文件)
- [ ] `Done/Views/*.swift` (4 个文件)
- [ ] `Done/ContentView.swift`

**如何添加：**
1. 在 Xcode 中选中文件
2. 在右侧 Inspector 的 "Target Membership" 中勾选对应的 target
3. 或者在 Project Navigator 中右键 > "Add Files to..."

### 2. 配置 Google OAuth

- [ ] 访问 [Google Cloud Console](https://console.cloud.google.com/)
- [ ] 创建项目
- [ ] 启用 Google Calendar API
- [ ] 创建 OAuth 2.0 Client ID (iOS)
- [ ] 获取 Client ID
- [ ] 更新 `GoogleCalendarService.swift` 中的配置：
  ```swift
  private let clientID = "YOUR_CLIENT_ID_HERE"
  private let redirectURI = "com.googleusercontent.apps.YOUR_CLIENT_ID:/oauth2redirect"
  ```
- [ ] 在 `Info.plist` 中添加 URL Scheme（见下方）

### 3. Info.plist 配置

在 iOS app 的 `Info.plist` 中添加：

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

### 4. 构建和运行

- [ ] 选择 iOS target，运行到 iPhone 模拟器或真机
- [ ] 选择 Watch App target，运行到 Watch 模拟器或真机
- [ ] 在 iPhone 上连接 Google Calendar
- [ ] 在 iPhone 上编辑模板
- [ ] 在 Watch 上开始追踪时间

## 📝 可选配置

### App Groups (用于更好的数据共享)

1. 在两个 targets 中添加 App Groups capability
2. 创建 group (例如：`group.com.yourcompany.Done`)
3. 更新 `DataManager.swift` 使用共享 UserDefaults：
   ```swift
   private let userDefaults = UserDefaults(suiteName: "group.com.yourcompany.Done")
   ```

### 更改 Bundle Identifier

1. 选择 iOS target
2. 在 General > Identity 中修改 Bundle Identifier
3. 对 Watch App 重复相同步骤
4. 确保 Google OAuth redirect URI 匹配新的 Bundle ID

## 🚀 验证安装

运行 checklist：

1. **Watch App**
   - [ ] 显示活动按钮网格
   - [ ] 点击按钮开始计时
   - [ ] 显示计时器界面
   - [ ] 停止后保存记录

2. **iOS App**
   - [ ] 显示 4 个 Tab (Templates, History, Analytics, Settings)
   - [ ] Templates: 可以添加/编辑/删除模板
   - [ ] History: 显示时间记录
   - [ ] Analytics: 显示图表（如果有数据）
   - [ ] Settings: 可以连接 Google Calendar

3. **数据同步**
   - [ ] iPhone 编辑模板后，Watch 上看到更新
   - [ ] Watch 记录时间后，iPhone 上看到记录
   - [ ] Google Calendar 中出现对应事件

## ❓ 遇到问题？

### 编译错误

- 确保所有文件都添加到了正确的 target
- 确保 iOS Deployment Target 至少是 iOS 16.0
- 确保 watchOS Deployment Target 至少是 watchOS 9.0

### Google 认证失败

- 检查 Client ID 配置
- 检查 Info.plist 中的 URL Scheme
- 确保 Google Calendar API 已启用
- 查看 Xcode 控制台的错误信息

### Watch 和 iPhone 不同步

- 确保两个设备已配对
- 检查蓝牙和 WiFi 连接
- 重启两个 app
- 查看 Xcode 控制台的 WatchConnectivity 日志

## 📚 下一步

完成设置后，你可以：

1. 自定义默认模板（在 `ActivityTemplate.swift` 中）
2. 调整 UI 样式和颜色
3. 添加更多功能（见 README.md 中的建议）
4. 发布到 App Store

祝你使用愉快！
