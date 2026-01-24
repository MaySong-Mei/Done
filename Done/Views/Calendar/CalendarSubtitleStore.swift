//
//  CalendarSubtitleStore.swift
//  Done
//
//  Created by Shiqi Liu on 1/22/26.
//

import Foundation

/// 功能： Loads and returns random subtitle strings for the calendar header.
enum CalendarSubtitleStore {
    private static let subdirectory = "CalendarSubtitles"
    private static let filename = "subtitles"
    private static let fileExtension = "txt"

    /// 功能： Returns a random subtitle string from bundled resources.
    static func randomSubtitle() -> String {
        guard let subtitles = loadSubtitles(), !subtitles.isEmpty else {
            return "shit，load nothing"
        }
        return subtitles.randomElement() ?? ""
    }

    /// 功能： Loads subtitle strings from the calendar subtitles resource file.
    private static func loadSubtitles() -> [String]? {
        let url = Bundle.main.url(
            forResource: filename,
            withExtension: fileExtension,
            subdirectory: subdirectory
        ) ?? Bundle.main.url(forResource: filename, withExtension: fileExtension)
        guard let resolvedUrl = url else { return nil }
        guard let contents = try? String(contentsOf: resolvedUrl, encoding: .utf8) else { return nil }
        return contents
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
