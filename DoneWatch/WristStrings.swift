//
//  WristStrings.swift
//  DoneWatch
//
//  The handful of strings the watch shows, in the language the phone app is
//  set to (`WristSnapshot.language`), falling back to the watch's locale.
//

import Foundation

struct WristStrings {
    let isChinese: Bool
    private let locale: Locale

    init(code: String?) {
        let resolved = code ?? Locale.current.language.languageCode?.identifier ?? "en"
        isChinese = resolved.hasPrefix("zh")
        locale = Locale(identifier: isChinese ? "zh_CN" : "en_US")
    }

    var appTitle: String { "Done" }
    var noPhoneData: String { isChinese ? "在 iPhone 上打开 Done,同步一次" : "Open Done on iPhone once to sync" }
    var noTypes: String { isChinese ? "iPhone 上还没有类型" : "No types on iPhone yet" }
    var finish: String { isChinese ? "结束" : "Finish" }
    var extend: String { "+15" }
    var editOnPhone: String { isChinese ? "重复事件请在 iPhone 上调整" : "Adjust repeating events on iPhone" }
    var sending: String { isChinese ? "发送中…" : "Sending…" }

    func sinceLastRecord(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval / 60))
        let hours = minutes / 60
        let rest = minutes % 60
        if isChinese {
            let span = hours > 0 ? (rest > 0 ? "\(hours) 小时 \(rest) 分钟" : "\(hours) 小时") : "\(minutes) 分钟"
            return "距上次记录 \(span)"
        }
        let span = hours > 0 ? (rest > 0 ? "\(hours)h \(rest)m" : "\(hours)h") : "\(minutes) min"
        return "\(span) since last record"
    }

    func endsAt(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        let time = formatter.string(from: date)
        return isChinese ? "到 \(time)" : "until \(time)"
    }

    var todayTitle: String { isChinese ? "今天" : "Today" }
    var weekTitle: String { isChinese ? "本周" : "This week" }
    var recordTitle: String { isChinese ? "记录" : "Record" }
    var statsTitle: String { isChinese ? "统计" : "Stats" }
    var unlogged: String { isChinese ? "未记录" : "Unlogged" }
    var others: String { isChinese ? "其他" : "Other" }
    var statsNoData: String { isChinese ? "打开 iPhone 上的 Done 更新统计" : "Open Done on iPhone to update stats" }
    var statsStale: String { isChinese ? "统计数据较旧,打开 iPhone 上的 Done 更新" : "Stats are out of date — open Done on iPhone" }
    var nothingLogged: String { isChinese ? "还没有记录" : "Nothing logged yet" }

    /// "2h 15m" / "2 小时 15 分"; minutes alone under an hour.
    func duration(hours: Double) -> String {
        let minutes = max(0, Int((hours * 60).rounded()))
        let h = minutes / 60, m = minutes % 60
        if isChinese {
            return h > 0 ? (m > 0 ? "\(h) 小时 \(m) 分" : "\(h) 小时") : "\(m) 分钟"
        }
        return h > 0 ? (m > 0 ? "\(h)h \(m)m" : "\(h)h") : "\(m)m"
    }

    /// "21h34m" / "21小时34分" — no spaces, for the clock row.
    func compactDuration(hours: Double) -> String {
        let minutes = max(0, Int((hours * 60).rounded()))
        let h = minutes / 60, m = minutes % 60
        if isChinese {
            return h > 0 ? (m > 0 ? "\(h)小时\(m)分" : "\(h)小时") : "\(m)分钟"
        }
        return h > 0 ? (m > 0 ? "\(h)h\(m)m" : "\(h)h") : "\(m)m"
    }

    func hourLabel(_ hour: Int) -> String { String(format: "%02d", hour) }

    func stale(_ age: TimeInterval) -> String {
        let hours = Int(age / 3600)
        return isChinese ? "iPhone 数据是 \(hours) 小时前的" : "iPhone data is \(hours)h old"
    }
}
