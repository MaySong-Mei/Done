//
//  ColorSystem.swift
//  Done
//
//  双层配色系统：品牌底色 + 类别强调色
//

import SwiftUI

// MARK: - 类别颜色键

enum CategoryColorKey: String, Codable, CaseIterable {
    case tomato
    case tangerine
    case banana
    case basil
    case sage
    case peacock
    case blueberry
    case lavender
    case grape
    case flamingo
    case graphite

    var displayName: String {
        switch self {
        case .tomato: return "Tomato"
        case .tangerine: return "Tangerine"
        case .banana: return "Banana"
        case .basil: return "Basil"
        case .sage: return "Sage"
        case .peacock: return "Peacock"
        case .blueberry: return "Blueberry"
        case .lavender: return "Lavender"
        case .grape: return "Grape"
        case .flamingo: return "Flamingo"
        case .graphite: return "Graphite"
        }
    }

    var defaultIcon: String {
        return "circle.fill"  // 默认图标，实际由模板指定
    }
}

// MARK: - 颜色系统

struct ColorSystem {

    // MARK: - 品牌底色（大面积）

    struct Brand {
        static let background = Color("AppBackground")
        static let cardSurface = Color("CardSurface")
        static let secondarySurface = Color("SecondarySurface")
        static let separator = Color("Separator")
        static let secondaryText = Color("SecondaryText")
    }

    // MARK: - 类别强调色（小面积）

    struct Category {
        let fill: Color        // 色块填充（深色，压白字）
        let tint: Color        // 浅底提示（浅色，压深字）
        let googleColorId: String  // Google Calendar 颜色 ID

        static func color(for key: CategoryColorKey, variant: ColorVariant = .standard) -> Category {
            switch variant {
            case .standard:
                return standardColors[key] ?? standardColors[.blueberry]!
            case .watch:
                return watchColors[key] ?? watchColors[.blueberry]!
            }
        }

        // 标准配色（iPhone - Google Calendar Modern）
        private static let standardColors: [CategoryColorKey: Category] = [
            .tomato: Category(
                fill: Color(hex: "#D50000")!,
                tint: Color(hex: "#FFCDD2")!,
                googleColorId: "11"
            ),
            .tangerine: Category(
                fill: Color(hex: "#F4511E")!,
                tint: Color(hex: "#FFCCBC")!,
                googleColorId: "6"
            ),
            .banana: Category(
                fill: Color(hex: "#F6BF26")!,
                tint: Color(hex: "#FFF9C4")!,
                googleColorId: "5"
            ),
            .basil: Category(
                fill: Color(hex: "#0B8043")!,
                tint: Color(hex: "#C8E6C9")!,
                googleColorId: "10"
            ),
            .sage: Category(
                fill: Color(hex: "#33B679")!,
                tint: Color(hex: "#B2DFDB")!,
                googleColorId: "2"
            ),
            .peacock: Category(
                fill: Color(hex: "#039BE5")!,
                tint: Color(hex: "#B3E5FC")!,
                googleColorId: "7"
            ),
            .blueberry: Category(
                fill: Color(hex: "#3F51B5")!,
                tint: Color(hex: "#C5CAE9")!,
                googleColorId: "9"
            ),
            .lavender: Category(
                fill: Color(hex: "#7986CB")!,
                tint: Color(hex: "#D1C4E9")!,
                googleColorId: "1"
            ),
            .grape: Category(
                fill: Color(hex: "#8E24AA")!,
                tint: Color(hex: "#E1BEE7")!,
                googleColorId: "3"
            ),
            .flamingo: Category(
                fill: Color(hex: "#E67C73")!,
                tint: Color(hex: "#F8BBD0")!,
                googleColorId: "4"
            ),
            .graphite: Category(
                fill: Color(hex: "#616161")!,
                tint: Color(hex: "#EEEEEE")!,
                googleColorId: "8"
            )
        ]

        // Watch 变体（对比度更强，加深 15%）
        private static let watchColors: [CategoryColorKey: Category] = [
            .tomato: Category(
                fill: Color(hex: "#B00020")!,
                tint: Color(hex: "#EFBDC2")!,
                googleColorId: "11"
            ),
            .tangerine: Category(
                fill: Color(hex: "#D84315")!,
                tint: Color(hex: "#EFBCAC")!,
                googleColorId: "6"
            ),
            .banana: Category(
                fill: Color(hex: "#D1A220")!,
                tint: Color(hex: "#EFE9B4")!,
                googleColorId: "5"
            ),
            .basil: Category(
                fill: Color(hex: "#056634")!,
                tint: Color(hex: "#B8D6B9")!,
                googleColorId: "10"
            ),
            .sage: Category(
                fill: Color(hex: "#2B9A67")!,
                tint: Color(hex: "#A2CFCB")!,
                googleColorId: "2"
            ),
            .peacock: Category(
                fill: Color(hex: "#0283C3")!,
                tint: Color(hex: "#A3D5EC")!,
                googleColorId: "7"
            ),
            .blueberry: Category(
                fill: Color(hex: "#303F9F")!,
                tint: Color(hex: "#B5BAD9")!,
                googleColorId: "9"
            ),
            .lavender: Category(
                fill: Color(hex: "#5C6BC0")!,
                tint: Color(hex: "#C1B4D9")!,
                googleColorId: "1"
            ),
            .grape: Category(
                fill: Color(hex: "#6A1B9A")!,
                tint: Color(hex: "#D1AED7")!,
                googleColorId: "3"
            ),
            .flamingo: Category(
                fill: Color(hex: "#D06A62")!,
                tint: Color(hex: "#E8ABA8")!,
                googleColorId: "4"
            ),
            .graphite: Category(
                fill: Color(hex: "#525252")!,
                tint: Color(hex: "#DEDEDE")!,
                googleColorId: "8"
            )
        ]
    }

    enum ColorVariant {
        case standard  // iPhone
        case watch     // Apple Watch（对比度更强）
    }
}

// MARK: - Color Asset 扩展（支持 Light/Dark）

extension Color {
    // 品牌底色从 Assets.xcassets 读取（支持 Light/Dark）
    static let appBackground = Color("AppBackground")
    static let cardSurface = Color("CardSurface")
    static let secondarySurface = Color("SecondarySurface")
    static let separator = Color("Separator")
    static let secondaryText = Color("SecondaryText")
}

// MARK: - 向后兼容：Hex -> ColorKey 转换

extension CategoryColorKey {
    /// 从旧的 Hex 值推断 ColorKey（用于数据迁移）
    static func from(hex: String) -> CategoryColorKey {
        let normalized = hex.uppercased()
        switch normalized {
        // Modern 颜色
        case "#D50000": return .tomato
        case "#F4511E": return .tangerine
        case "#F6BF26": return .banana
        case "#0B8043": return .basil
        case "#33B679": return .sage
        case "#039BE5": return .peacock
        case "#3F51B5": return .blueberry
        case "#7986CB": return .lavender
        case "#8E24AA": return .grape
        case "#E67C73": return .flamingo
        case "#616161": return .graphite
        // 旧系统颜色（iOS 默认）- 映射到最接近的 Modern 颜色
        case "#007AFF": return .blueberry
        case "#34C759": return .sage
        case "#FF9500": return .tangerine
        case "#AF52DE": return .grape
        case "#FF3B30": return .tomato
        case "#5856D6": return .lavender
        default: return .blueberry  // 默认值
        }
    }

    /// 导出为 Hex（用于外部系统/调试）
    var hexValue: String {
        let category = ColorSystem.Category.color(for: self)
        return category.fill.toHex() ?? "#3F51B5"
    }
}
