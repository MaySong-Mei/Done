//
//  ReportStore.swift
//  Done
//
//  File-per-report JSON persistence for the generative report system
//  (Discussion #111).
//
//  Each report is its own file at `Documents/Reports/<uuid>.json`.  One file
//  per report (rather than a single manifest array) keeps writes atomic and
//  independent: saving or deleting one report never rewrites the others, and a
//  single corrupt file can't take the whole history down — `loadAll` skips it
//  and moves on.
//
//  A report carries its own `statsSnapshot`, so it stays reproducible after the
//  underlying events are edited: the prose and the numbers it rests on are
//  frozen together at generation time and never recomputed from live data.
//
//  Pure Foundation — no SwiftData / CoreData / Supabase.  This is a local cache;
//  cloud sync of reports, if it ever happens, is a separate concern.
//

import Foundation
import os

private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Done",
    category: "ReportStore"
)

/// One generated report: the prose plus the exact statistical snapshot it was
/// written from.  `Codable` so the whole thing round-trips through one JSON
/// file; `schemaVersion` lets a future format change be detected and skipped
/// rather than crash a decode.
struct Report: Codable, Identifiable, Hashable {
    /// Bump when `Report` or any nested stats type changes shape in a way that
    /// makes older files undecodable; `ReportStore.loadAll` skips files whose
    /// version it doesn't recognize.
    static let currentSchemaVersion = 1

    var id: UUID
    /// Wall-clock moment the report was generated, injected by the caller (the
    /// stats/prose pipeline is itself wall-clock-free).  Drives `loadAll` order.
    var createdAt: Date
    var periodStart: Date
    var periodEnd: Date
    /// The language model's markdown prose — the only free-text field.
    var prose: String
    /// The stats the prose was written from, frozen so the report reproduces its
    /// own basis even after the source events change.
    var statsSnapshot: ReportStats
    /// Provider model identifier used for the prose (e.g. the Claude/OpenAI model
    /// string), recorded for provenance.
    var providerModel: String
    var schemaVersion: Int
}

final class ReportStore {

    private let fileManager: FileManager
    private let directoryURL: URL

    /// - Parameter directoryURL: override the storage location (tests); defaults
    ///   to `Documents/Reports`.
    init(fileManager: FileManager = .default, directoryURL: URL? = nil) {
        self.fileManager = fileManager
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            self.directoryURL = documents.appendingPathComponent("Reports", isDirectory: true)
        }
    }

    // MARK: - API

    func save(_ report: Report) throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try data.write(to: fileURL(for: report.id), options: .atomic)
    }

    /// Every stored report, newest first.  Unreadable, undecodable, or
    /// unrecognized-version files are logged and skipped, never fatal.
    func loadAll() -> [Report] {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var reports: [Report] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file) else {
                logger.error("Unreadable report file, skipping: \(file.lastPathComponent, privacy: .public)")
                continue
            }
            do {
                let report = try decoder.decode(Report.self, from: data)
                guard report.schemaVersion == Report.currentSchemaVersion else {
                    logger.notice("Unknown report schemaVersion \(report.schemaVersion), skipping: \(file.lastPathComponent, privacy: .public)")
                    continue
                }
                reports.append(report)
            } catch {
                logger.error("Corrupt report file, skipping: \(file.lastPathComponent, privacy: .public) — \(error.localizedDescription, privacy: .public)")
            }
        }
        return reports.sorted { $0.createdAt > $1.createdAt }
    }

    func delete(id: UUID) throws {
        let url = fileURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    // MARK: - Private

    private func ensureDirectory() throws {
        guard !fileManager.fileExists(atPath: directoryURL.path) else { return }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func fileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).json")
    }
}
