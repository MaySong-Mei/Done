#!/bin/bash

echo "🔧 自动修复 Xcode 项目..."
echo ""

cd "$(dirname "$0")"

# 颜色定义
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo "步骤 1: 清理环境..."
echo "-------------------"

# 关闭 Xcode（如果打开）
echo "正在关闭 Xcode..."
osascript -e 'quit app "Xcode"' 2>/dev/null
sleep 2

# 清理 DerivedData
echo "清理 DerivedData..."
rm -rf ~/Library/Developer/Xcode/DerivedData/Done-*

echo -e "${GREEN}✓ 环境清理完成${NC}"
echo ""

echo "步骤 2: 验证文件完整性..."
echo "-------------------------"

# 检查 iOS 文件
ios_files=(
    "Done/Models/ActivityTemplate.swift"
    "Done/Models/TimeEntry.swift"
    "Done/Models/SyncMessage.swift"
    "Done/Extensions/Color+Hex.swift"
    "Done/Extensions/TimeInterval+Format.swift"
    "Done/Protocols/DataStorage.swift"
)

watchos_files=(
    "Done Watch App/Models/ActivityTemplate.swift"
    "Done Watch App/Models/TimeEntry.swift"
    "Done Watch App/Models/SyncMessage.swift"
    "Done Watch App/Extensions/Color+Hex.swift"
    "Done Watch App/Extensions/TimeInterval+Format.swift"
    "Done Watch App/Protocols/DataStorage.swift"
)

errors=0

echo "检查 iOS 文件..."
for file in "${ios_files[@]}"; do
    if [ -f "$file" ]; then
        echo -e "${GREEN}✓${NC} $file"
    else
        echo -e "${RED}✗${NC} $file ${RED}缺失${NC}"
        ((errors++))
    fi
done

echo ""
echo "检查 watchOS 文件..."
for file in "${watchos_files[@]}"; do
    if [ -f "$file" ]; then
        echo -e "${GREEN}✓${NC} $file"
    else
        echo -e "${RED}✗${NC} $file ${RED}缺失${NC}"
        ((errors++))
    fi
done

if [ $errors -gt 0 ]; then
    echo ""
    echo -e "${RED}错误: 发现 $errors 个缺失文件${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}✓ 所有文件完整${NC}"
echo ""

echo "步骤 3: 准备在 Xcode 中添加文件..."
echo "-----------------------------------"

cat << 'EOF'

现在请按以下步骤操作：

1. 打开 Xcode 项目：
   $ open Done.xcodeproj

2. 等待 Xcode 完全打开（右上角索引完成）

3. 添加 iOS 文件：
   - 顶部菜单: File → Add Files to "Done"...
   - 导航到项目文件夹
   - 按住 Cmd 键，依次点击选中：
     • Done/Models 文件夹
     • Done/Extensions 文件夹
     • Done/Protocols 文件夹
   - 在底部 Options 中：
     ☐ Copy items if needed (不要勾选)
     • Create groups (选中)
     ☑ Add to targets: Done (只勾选这个)
   - 点击 Add

4. 添加 watchOS 文件：
   - 顶部菜单: File → Add Files to "Done"...
   - 导航到项目文件夹
   - 按住 Cmd 键，选中：
     • Done Watch App/Models 文件夹
     • Done Watch App/Extensions 文件夹
     • Done Watch App/Protocols 文件夹
   - 在底部 Options 中：
     ☐ Copy items if needed (不要勾选)
     • Create groups (选中)
     ☑ Add to targets: Done Watch App (只勾选这个)
   - 点击 Add

5. Clean & Build:
   ⇧⌘K (Shift + Cmd + K)
   ⌘B (Cmd + B)

EOF

echo ""
echo "================================"
echo "准备完成！"
echo ""
echo -e "${YELLOW}现在打开 Xcode 并按照上面的步骤操作${NC}"
echo ""
echo "如果需要再次查看这些步骤，运行:"
echo "  cat fix_xcode_project.sh"
echo "================================"
