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

    func stale(_ age: TimeInterval) -> String {
        let hours = Int(age / 3600)
        return isChinese ? "iPhone 数据是 \(hours) 小时前的" : "iPhone data is \(hours)h old"
    }
}
