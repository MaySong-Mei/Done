#!/bin/bash

echo "🧹 清理构建..."
echo ""

# 1. 清理派生数据
echo "1. 清理 DerivedData..."
rm -rf ~/Library/Developer/Xcode/DerivedData/Done-*
echo "✅ DerivedData 已清理"

# 2. 清理项目构建
echo ""
echo "2. 清理项目构建文件..."
cd "$(dirname "$0")"

# 清理 iOS target
xcodebuild clean -project Done.xcodeproj -scheme "Done" -configuration Debug 2>&1 | grep -v "^$" | head -5

# 清理 Watch target
xcodebuild clean -project Done.xcodeproj -scheme "Done Watch App" -configuration Debug 2>&1 | grep -v "^$" | head -5

echo "✅ 构建文件已清理"

echo ""
echo "================================"
echo "清理完成！"
echo ""
echo "下一步："
echo "1. 在 Xcode 中关闭项目"
echo "2. 重新打开 Done.xcodeproj"
echo "3. 检查以下文件的 Target Membership："
echo ""
echo "   Done/ContentView.swift:"
echo "   ☑ Done"
echo "   ☐ Done Watch App (应该取消勾选！)"
echo ""
echo "   Done Watch App/ContentView.swift:"
echo "   ☐ Done (应该取消勾选！)"
echo "   ☑ Done Watch App"
echo ""
echo "4. Product > Clean Build Folder (⇧⌘K)"
echo "5. Product > Build (⌘B)"
echo "================================"
