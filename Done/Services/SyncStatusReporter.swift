import Foundation
import Combine

/// Snapshot of one sync channel's state for UI display. Equatable so SwiftUI
/// can skip redundant view updates when nothing meaningful changed.
struct SyncChannelStatus: Equatable {
    /// Wall-clock time of the most recent successful completion, or nil if
    /// the channel has never successfully synced this session.
    var lastCompletedAt: Date?

    /// True while at least one operation is currently in flight on this
    /// channel. Multiple back-to-back operations are coalesced via a
    /// reference-counter style (see `SyncStatusReporter`).
    var isActive: Bool = false

    /// Last error message from this channel, if recent. Cleared on next
    /// successful completion.
    var lastError: String?

    /// Free-form summary the channel surfaces (e.g. "287 images uploaded",
    /// "1.0 MB"). Renderer may show beside the timestamp.
    var detail: String?
}

/// Single observation point for the three backup channels (structured data,
/// image binaries, local device-backup snapshot). Services call into this on
/// activity boundaries; `DataPrivacySettingsView` observes via `@EnvironmentObject`.
///
/// **Why a single reporter** instead of three @Published properties on each
/// service: settings UI then only needs ONE env object, and services stay
/// focused on their primary job.
///
/// **Structured channel uses a burst API.** A "full sync" pass touches many
/// tables in sequence (events / logs / feedback / todoLists / event-types /
/// skills / settings). If each table emitted its own succeed, the UI would
/// only ever show the *last* table's detail — losing the aggregate that the
/// user actually wants ("how much synced"). Callers wrap a multi-table pass
/// with `structuredBeginBurst` / `structuredEndBurst` and feed each table's
/// result through `structuredRecord(...)`. The reporter holds emission until
/// the outermost burst closes, then emits a single aggregate.
///
/// **Images & snapshot** use the simpler start/succeed/fail API since their
/// callers don't span multiple sub-operations the user cares to aggregate.
@MainActor
final class SyncStatusReporter: ObservableObject {
    @Published private(set) var structured = SyncChannelStatus()
    @Published private(set) var images = SyncChannelStatus()
    @Published private(set) var snapshot = SyncChannelStatus()

    /// Burst nesting depth (>0 → reporter is buffering structured results).
    private var structuredBurstDepth = 0
    private var structuredBurstUpserts = 0
    private var structuredBurstDeletes = 0
    private var structuredBurstTables: Set<String> = []
    private var structuredBurstErrors: [String] = []

    /// Per-channel in-flight counters for the simple API (images, snapshot).
    private var imagesInFlight = 0
    private var snapshotInFlight = 0

    // MARK: - Structured (burst API)

    func structuredBeginBurst() {
        structuredBurstDepth += 1
        if structuredBurstDepth == 1 {
            structuredBurstUpserts = 0
            structuredBurstDeletes = 0
            structuredBurstTables = []
            structuredBurstErrors = []
            var s = structured
            s.isActive = true
            structured = s
        }
    }

    func structuredEndBurst() {
        structuredBurstDepth = max(0, structuredBurstDepth - 1)
        guard structuredBurstDepth == 0 else { return }

        let tableCount = structuredBurstTables.count
        var workParts: [String] = []
        if structuredBurstUpserts > 0 { workParts.append("\(structuredBurstUpserts) up") }
        if structuredBurstDeletes > 0 { workParts.append("\(structuredBurstDeletes) del") }
        // A no-change burst still represents a successful "we checked, nothing
        // to do" outcome — we deliberately overwrite any stale detail from a
        // prior sync so the user doesn't see e.g. "5 up across 2 tables" still
        // sitting there hours later. Use a fixed "no changes" string instead.
        let detail: String
        if workParts.isEmpty {
            detail = "no changes"
        } else {
            let tablesLabel = tableCount == 1 ? "1 table" : "\(tableCount) tables"
            detail = "\(workParts.joined(separator: ", ")) across \(tablesLabel)"
        }

        if structuredBurstErrors.isEmpty {
            structured = SyncChannelStatus(
                lastCompletedAt: Date(),
                isActive: false,
                lastError: nil,
                detail: detail
            )
        } else {
            structured = SyncChannelStatus(
                lastCompletedAt: structured.lastCompletedAt,
                isActive: false,
                lastError: structuredBurstErrors.joined(separator: "; "),
                detail: detail
            )
        }
    }

    /// Record one table's outcome. Inside a burst, accumulates; outside,
    /// emits immediately as a single-table completion.
    func structuredRecord(table: String, upserts: Int, deletes: Int) {
        if structuredBurstDepth > 0 {
            structuredBurstUpserts += upserts
            structuredBurstDeletes += deletes
            if upserts > 0 || deletes > 0 {
                structuredBurstTables.insert(table)
            }
            return
        }
        var workParts: [String] = []
        if upserts > 0 { workParts.append("\(upserts) up") }
        if deletes > 0 { workParts.append("\(deletes) del") }
        let detail = workParts.isEmpty ? structured.detail : "\(table): \(workParts.joined(separator: ", "))"
        structured = SyncChannelStatus(
            lastCompletedAt: Date(),
            isActive: false,
            lastError: nil,
            detail: detail
        )
    }

    func structuredRecordFailure(table: String, error: String) {
        if structuredBurstDepth > 0 {
            structuredBurstErrors.append("\(table): \(error)")
            structuredBurstTables.insert(table)
            return
        }
        structured = SyncChannelStatus(
            lastCompletedAt: structured.lastCompletedAt,
            isActive: false,
            lastError: "\(table): \(error)",
            detail: structured.detail
        )
    }

    // MARK: - Images (Supabase Storage)

    func imagesDidStart() {
        imagesInFlight += 1
        images.isActive = true
    }

    func imagesDidSucceed(detail: String? = nil) {
        imagesInFlight = max(0, imagesInFlight - 1)
        images = SyncChannelStatus(
            lastCompletedAt: Date(),
            isActive: imagesInFlight > 0,
            lastError: nil,
            detail: detail ?? images.detail
        )
    }

    func imagesDidFail(_ error: String) {
        imagesInFlight = max(0, imagesInFlight - 1)
        var s = images
        s.isActive = imagesInFlight > 0
        s.lastError = error
        images = s
    }

    /// Record a no-op (e.g. DEBUG path where uploads are disabled). Updates
    /// `detail` and timestamp so the UI doesn't claim a successful upload that
    /// never happened.
    func imagesDidNoOp(detail: String) {
        images = SyncChannelStatus(
            lastCompletedAt: Date(),
            isActive: imagesInFlight > 0,
            lastError: nil,
            detail: detail
        )
    }

    // MARK: - Snapshot (Documents/backup-snapshot.json)

    func snapshotDidStart() {
        snapshotInFlight += 1
        snapshot.isActive = true
    }

    func snapshotDidSucceed(byteCount: Int) {
        snapshotInFlight = max(0, snapshotInFlight - 1)
        snapshot = SyncChannelStatus(
            lastCompletedAt: Date(),
            isActive: snapshotInFlight > 0,
            lastError: nil,
            detail: formatSize(byteCount)
        )
    }

    func snapshotDidFail(_ error: String) {
        snapshotInFlight = max(0, snapshotInFlight - 1)
        var s = snapshot
        s.isActive = snapshotInFlight > 0
        s.lastError = error
        snapshot = s
    }

    // MARK: - Formatting helpers

    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }
}
