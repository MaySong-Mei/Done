//
//  WristStrings.swift
//  DoneWatch
//
//  The strings the watch shows, in the language the phone app is
//  set to (`WristSnapshot.language`), falling back to the watch's locale.
//

import SwiftUI

struct WristStrings {
    let isChinese: Bool
    private let locale: Locale

    init(code: String?) {
        let resolved = code ?? Locale.current.language.languageCode?.identifier ?? "en"
        isChinese = resolved.hasPrefix("zh")
        locale = Locale(identifier: isChinese ? "zh_CN" : "en_US")
    }

    var noPhoneData: String { isChinese ? "在 iPhone 上打开 Done,同步一次" : "Open Done on iPhone once to sync" }
    var noTypes: String { isChinese ? "iPhone 上还没有类型" : "No types on iPhone yet" }
    var finish: String { isChinese ? "结束" : "Finish" }
    var extend: String { "+15" }
    var sending: String { isChinese ? "发送中…" : "Sending…" }
    /// The names step's last row: the block named after its type alone.
    func justType(_ type: String) -> String { isChinese ? "仅「\(type)」" : "Just \(type)" }

    var editOnPhoneShort: String { isChinese ? "在 iPhone 上调整" : "Adjust on iPhone" }
    /// A hold on a block the phone does not let the watch move (a repeating
    /// event, a running timer).
    var cannotMoveHere: String { isChinese ? "这里不能移动,请在 iPhone 上调整" : "Can't move this here — adjust on iPhone" }
    var updatePhoneForEdits: String {
        isChinese ? "更新 iPhone 上的 Done 后可在这里移动" : "Update Done on iPhone to move blocks here"
    }
    var endEarlier: String { isChinese ? "结束 −15" : "End −15" }
    var endLater: String { isChinese ? "结束 +15" : "End +15" }
    var close: String { isChinese ? "关闭" : "Close" }

    /// "10:15–11:00": a drawn block's range, on the block and over the
    /// type picker.
    func timeRange(_ start: Date, _ end: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: start))–\(formatter.string(from: end))"
    }

    func periodLabel(_ period: WristStatsPeriod) -> String {
        switch period {
        case .today: return isChinese ? "今天" : "Today"
        case .threeDays: return isChinese ? "近 3 天" : "Last 3 Days"
        case .sevenDays: return isChinese ? "近 7 天" : "Last 7 Days"
        case .thirtyDays: return isChinese ? "近 30 天" : "Last 30 Days"
        }
    }

    var unlogged: String { isChinese ? "未记录" : "Unlogged" }
    var others: String { isChinese ? "其他" : "Other" }
    var statsNoData: String { isChinese ? "打开 iPhone 上的 Done 更新统计" : "Open Done on iPhone to update stats" }
    var statsStale: String { isChinese ? "统计数据较旧,打开 iPhone 上的 Done 更新" : "Stats are out of date — open Done on iPhone" }
    var statsLeftOut: String { isChinese ? "这一段还没同步到手表,请在 iPhone 上查看" : "Not on the watch yet — see it on iPhone" }
    var nothingLogged: String { isChinese ? "还没有记录" : "Nothing logged yet" }

    /// "21h34m" / "21小时34分" — no spaces, for the clock row.
    func compactDuration(hours: Double) -> String {
        let minutes = max(0, Int((hours * 60).rounded()))
        let h = minutes / 60, m = minutes % 60
        if isChinese {
            return h > 0 ? (m > 0 ? "\(h)小时\(m)分" : "\(h)小时") : "\(m)分钟"
        }
        return h > 0 ? (m > 0 ? "\(h)h\(m)m" : "\(h)h") : "\(m)m"
    }

    // MARK: Settings page

    var settingsTitle: String { isChinese ? "设置" : "Settings" }
    var settingsOnWatch: String { isChinese ? "手表" : "On This Watch" }
    var settingsFromPhone: String { isChinese ? "统计(与 iPhone 同步)" : "Stats (Shared with iPhone)" }
    var zoom: String { isChinese ? "时间轴缩放" : "Timeline Zoom" }
    func zoomLabel(_ zoom: WristLocalSettings.Zoom) -> String {
        switch zoom {
        case .small: return isChinese ? "小" : "Small"
        case .medium: return isChinese ? "中" : "Medium"
        case .large: return isChinese ? "大" : "Large"
        }
    }
    var statsOpensOn: String { isChinese ? "统计默认周期" : "Stats Opens On" }
    /// The period choice that defers to the phone, naming what the phone
    /// chose: "跟随 iPhone(今天)" / "As iPhone (Today)".
    func followPhone(_ period: WristStatsPeriod) -> String {
        isChinese ? "跟随 iPhone(\(periodLabel(period)))" : "As iPhone (\(periodLabel(period)))"
    }
    var overlap: String { isChinese ? "重叠事件" : "Overlapping Events" }
    func overlapLabel(_ rule: WristOverlapRule) -> String {
        switch rule {
        case .split: return isChinese ? "平分" : "Split Equally"
        case .full: return isChinese ? "各自全算" : "Count Each in Full"
        case .latestStart: return isChinese ? "后开始的优先" : "Latest Started Wins"
        }
    }
    var leaveOutBackground: String { isChinese ? "不统计背景类型" : "Leave Out Background Types" }
    /// Which types count is chosen on the phone only.
    func typesOnPhone(leftOut: Int) -> String {
        if leftOut > 0 {
            return isChinese
                ? "已有 \(leftOut) 个类型不统计。统计哪些类型在 iPhone 的 设置 → Apple Watch 里选。"
                : "\(leftOut) \(leftOut == 1 ? "type" : "types") left out. Pick which types count in Settings → Apple Watch on iPhone."
        }
        return isChinese
            ? "统计哪些类型在 iPhone 的 设置 → Apple Watch 里选。"
            : "Pick which types count in Settings → Apple Watch on iPhone."
    }
    var updatePhoneForSettings: String {
        isChinese ? "更新 iPhone 上的 Done 后可在这里修改" : "Update Done on iPhone to change these here"
    }

    func hourLabel(_ hour: Int) -> String { String(format: "%02d", hour) }

    func stale(_ age: TimeInterval) -> String {
        let hours = Int(age / 3600)
        return isChinese ? "iPhone 数据是 \(hours) 小时前的" : "iPhone data is \(hours)h old"
    }
}
