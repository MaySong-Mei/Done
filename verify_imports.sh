#!/bin/bash

# 验证所有必需的导入是否存在

echo "🔍 验证项目导入..."
echo ""

errors=0

# 检查 Combine 导入
echo "检查 Combine 导入..."

files=(
    "Done/Services/GoogleCalendarService.swift"
    "Done/Services/PhoneConnectivityManager.swift"
    "Done Watch App/Services/WatchConnectivityManager.swift"
)

for file in "${files[@]}"; do
    if grep -q "import Combine" "$file"; then
        echo "✅ $file - Combine 已导入"
    else
        echo "❌ $file - 缺少 Combine 导入"
        ((errors++))
    fi
done

echo ""

# 检查条件编译
echo "检查跨平台兼容性..."

files=(
    "Done/Models/ActivityTemplate.swift"
    "Done Watch App/Models/ActivityTemplate.swift"
)

for file in "${files[@]}"; do
    if grep -q "#if os(iOS)" "$file"; then
        echo "✅ $file - 已添加条件编译"
    else
        echo "❌ $file - 缺少条件编译"
        ((errors++))
    fi
done

echo ""

# 检查文件存在性
echo "检查文件完整性..."

required_files=(
    "Done/Models/ActivityTemplate.swift"
    "Done/Models/TimeEntry.swift"
    "Done/Models/SyncMessage.swift"
    "Done/Services/DataManager.swift"
    "Done/Services/PhoneConnectivityManager.swift"
    "Done/Services/GoogleCalendarService.swift"
    "Done/Views/TemplateManagementView.swift"
    "Done/Views/TimeEntriesView.swift"
    "Done/Views/AnalyticsView.swift"
    "Done/Views/SettingsView.swift"
    "Done/ContentView.swift"
    "Done Watch App/Models/ActivityTemplate.swift"
    "Done Watch App/Models/TimeEntry.swift"
    "Done Watch App/Models/SyncMessage.swift"
    "Done Watch App/Services/DataManager.swift"
    "Done Watch App/Services/WatchConnectivityManager.swift"
    "Done Watch App/ContentView.swift"
)

for file in "${required_files[@]}"; do
    if [ -f "$file" ]; then
        echo "✅ $file 存在"
    else
        echo "❌ $file 不存在"
        ((errors++))
    fi
done

echo ""
echo "================================"

if [ $errors -eq 0 ]; then
    echo "🎉 所有检查通过！"
    echo ""
    echo "下一步："
    echo "1. 在 Xcode 中打开 Done.xcodeproj"
    echo "2. 为每个文件配置 Target Membership"
    echo "3. 配置 Google OAuth (见 SETUP.md)"
    echo "4. 构建项目 (⌘B)"
else
    echo "⚠️  发现 $errors 个问题"
    echo ""
    echo "请检查上面标记为 ❌ 的项目"
fi

echo "================================"
