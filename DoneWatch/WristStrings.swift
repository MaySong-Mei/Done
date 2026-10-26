//
//  WristStrings.swift
//  DoneWatch
//
//  The handful of strings the watch shows, in the language the phone app is
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
    var editOnPhone: String { isChinese ? "重复事件请在 iPhone 上调整" : "Adjust repeating events on iPhone" }
    var sending: String { isChinese ? "发送中…" : "Sending…" }

    /// The record page's clock row: "距上次 2小时16分" / "2h16m since last",
    /// the time in white.
    func sinceLastHeader(hours: Double) -> Text {
        let span = Text(compactDuration(hours: hours)).foregroundStyle(.white)
        return isChinese
            ? Text("距上次 ").foregroundStyle(.secondary) + span
            : span + Text(" since last").foregroundStyle(.secondary)
    }

    func endsAt(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        let time = formatter.string(from: date)
        return isChinese ? "到 \(time)" : "until \(time)"
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

    func hourLabel(_ hour: Int) -> String { String(format: "%02d", hour) }

    func stale(_ age: TimeInterval) -> String {
        let hours = Int(age / 3600)
        return isChinese ? "iPhone 数据是 \(hours) 小时前的" : "iPhone data is \(hours)h old"
    }
}
