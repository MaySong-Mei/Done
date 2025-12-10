#!/bin/bash

echo "🔨 重建项目..."
echo ""

cd "$(dirname "$0")"

echo "步骤 1: 清理派生数据..."
rm -rf ~/Library/Developer/Xcode/DerivedData/Done-*
echo "✅ 完成"

echo ""
echo "步骤 2: 在 Xcode 中执行以下操作："
echo ""
echo "   1. Product > Clean Build Folder (⇧⌘K)"
echo "   2. 关闭项目: File > Close Project"
echo "   3. 重新打开: Done.xcodeproj"
echo "   4. 等待索引完成（右上角）"
echo "   5. Product > Build (⌘B)"
echo ""
echo "✨ 构建应该成功，所有 22 个错误消失！"
