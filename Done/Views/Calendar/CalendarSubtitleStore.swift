//
//  CalendarSubtitleStore.swift
//  Done
//
//  Created by Shiqi Liu on 1/22/26.
//

import Foundation

enum CalendarSubtitleStore {
    private static let subdirectory = "CalendarSubtitles"
    private static let filename = "subtitles"
    private static let fileExtension = "txt"

    static func randomSubtitle() -> String {
        guard let subtitles = loadSubtitles(), !subtitles.isEmpty else {
            return "shit，load nothing"
        }
        return subtitles.randomElement() ?? ""
    }

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
