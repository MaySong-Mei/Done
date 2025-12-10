#!/bin/bash

echo "🔧 修复 Xcode Target Membership..."
echo ""

# 进入项目目录
cd "$(dirname "$0")"

echo "1. 清理 Xcode 派生数据..."
rm -rf ~/Library/Developer/Xcode/DerivedData/Done-*

echo "✅ 派生数据已清理"
echo ""

echo "2. 清理构建文件..."
xcodebuild clean -project Done.xcodeproj -scheme "Done" 2>/dev/null
xcodebuild clean -project Done.xcodeproj -scheme "Done Watch App" 2>/dev/null

echo "✅ 构建文件已清理"
echo ""

echo "3. 构建 iOS App..."
xcodebuild build -project Done.xcodeproj -scheme "Done" -destination "generic/platform=iOS" 2>&1 | grep -E "(error|warning|Build Succeeded)" | head -20

echo ""
echo "4. 构建 Watch App..."
xcodebuild build -project Done.xcodeproj -scheme "Done Watch App" -destination "generic/platform=watchOS" 2>&1 | grep -E "(error|warning|Build Succeeded)" | head -20

echo ""
echo "================================"
echo "修复完成！"
echo ""
echo "下一步："
echo "1. 在 Xcode 中关闭项目"
echo "2. 重新打开 Done.xcodeproj"
echo "3. 等待索引完成（右上角进度条）"
echo "4. 尝试预览或构建"
echo "================================"
