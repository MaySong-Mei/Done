import XCTest
@testable import Done

/// `DiagnosticTrail` writes to a fixed location in Application Support and is
/// deliberately process-global (it has to be usable from anywhere, including
/// teardown). These tests therefore share one real directory — each starts by
/// clearing it, and they assert on content they wrote themselves.
final class DiagnosticTrailTests: XCTestCase {
    override func setUp() {
        super.setUp()
        DiagnosticTrail.clear()
    }

    override func tearDown() {
        DiagnosticTrail.clear()
        super.tearDown()
    }

    // MARK: - The reason this exists

    /// The load-bearing property: an entry is on disk by the time `record`
    /// returns, readable by a *separate* reader. That is what makes it survive
    /// a process that never gets to run any teardown.
    func testEntryIsReadableFromDiskImmediatelyAfterRecording() {
        DiagnosticTrail.record("Persistence", "save calendar: count=42")

        let onDisk = try? String(contentsOf: DiagnosticTrail.liveURL, encoding: .utf8)
        XCTAssertNotNil(onDisk)
        XCTAssertTrue(onDisk?.contains("save calendar: count=42") == true)
    }

    func testFirstEntryOfAProcessIsPrecededByALaunchBanner() {
        DiagnosticTrail.record("Persistence", "load: calendar=7")

        let text = DiagnosticTrail.combinedText()
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2, "expected banner + entry, got: \(text)")
        XCTAssertTrue(lines[0].contains("==== LAUNCH"))
        XCTAssertTrue(lines[1].contains("load: calendar=7"))
    }

    func testEveryEntryCarriesTheSameSessionIDWithinAProcess() {
        DiagnosticTrail.record("Persistence", "first")
        DiagnosticTrail.record("Persistence", "second")

        let ids = DiagnosticTrail.combinedText()
            .split(separator: "\n")
            .compactMap { line -> Substring? in
                guard let open = line.firstIndex(of: "["), let close = line.firstIndex(of: "]") else { return nil }
                return line[line.index(after: open)..<close]
            }
        XCTAssertEqual(ids.count, 3, "banner + two entries")
        XCTAssertEqual(Set(ids).count, 1, "one process ⇒ one session id")
    }

    // MARK: - Bounded retention

    func testRotationKeepsHistoryInsteadOfDiscardingIt() {
        // Enough to cross the rotation threshold several times over.
        let payload = String(repeating: "x", count: 512)
        var written = 0
        while written < DiagnosticTrail.rotateAtBytes * 2 {
            DiagnosticTrail.record("Persistence", payload)
            written += payload.count
        }

        // Both files exist, so the retained window spans a rotation rather
        // than being truncated back to empty.
        XCTAssertTrue(FileManager.default.fileExists(atPath: DiagnosticTrail.rotatedURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: DiagnosticTrail.liveURL.path))
        XCTAssertGreaterThan(DiagnosticTrail.retainedByteCount, DiagnosticTrail.rotateAtBytes)
    }

    func testRetentionStaysBoundedUnderSustainedWriting() {
        let payload = String(repeating: "y", count: 512)
        for _ in 0..<((DiagnosticTrail.rotateAtBytes * 4) / payload.count) {
            DiagnosticTrail.record("Persistence", payload)
        }
        // Two files, each capped at the rotation threshold — the point of
        // rotating at all is that an app left running for weeks cannot fill
        // the container.
        XCTAssertLessThanOrEqual(
            DiagnosticTrail.retainedByteCount,
            DiagnosticTrail.rotateAtBytes * 2 + 4096,
            "retention must stay bounded"
        )
    }

    func testCombinedTextReadsOlderRotatedContentBeforeNewer() {
        DiagnosticTrail.record("Persistence", "MARKER_OLDEST")
        let payload = String(repeating: "z", count: 512)
        while DiagnosticTrail.retainedByteCount < DiagnosticTrail.rotateAtBytes + 1024 {
            DiagnosticTrail.record("Persistence", payload)
        }
        DiagnosticTrail.record("Persistence", "MARKER_NEWEST")

        let text = DiagnosticTrail.combinedText()
        guard let oldest = text.range(of: "MARKER_OLDEST"), let newest = text.range(of: "MARKER_NEWEST") else {
            return XCTFail("both markers should still be retained")
        }
        XCTAssertLessThan(oldest.lowerBound, newest.lowerBound, "oldest-first ordering")
    }

    // MARK: - Export & clearing

    func testExportProducesAFileMatchingWhatIsRetained() throws {
        DiagnosticTrail.record("Persistence", "deleteCalendarEvent id=ABC")

        let url = try XCTUnwrap(DiagnosticTrail.exportFile())
        let exported = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(exported, DiagnosticTrail.combinedText())
        XCTAssertTrue(exported.contains("deleteCalendarEvent id=ABC"))
    }

    func testExportIsNilWhenNothingHasBeenRecorded() {
        XCTAssertNil(DiagnosticTrail.exportFile())
    }

    func testClearRemovesBothFiles() {
        let payload = String(repeating: "w", count: 512)
        while DiagnosticTrail.retainedByteCount < DiagnosticTrail.rotateAtBytes + 1024 {
            DiagnosticTrail.record("Persistence", payload)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: DiagnosticTrail.rotatedURL.path))

        DiagnosticTrail.clear()

        XCTAssertEqual(DiagnosticTrail.retainedByteCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: DiagnosticTrail.liveURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: DiagnosticTrail.rotatedURL.path))
    }

    /// Clearing must not leave the writer wedged — the app keeps running after
    /// "erase local data" and its next mutation still needs to be recorded.
    func testRecordingStillWorksAfterAClear() {
        DiagnosticTrail.record("Persistence", "before")
        DiagnosticTrail.clear()
        DiagnosticTrail.record("Persistence", "after")

        let text = DiagnosticTrail.combinedText()
        XCTAssertFalse(text.contains("before"))
        XCTAssertTrue(text.contains("after"))
        XCTAssertTrue(text.contains("==== LAUNCH"), "a cleared trail re-banners so the file is self-describing")
    }

    /// A deleted file underneath a live handle must not silently swallow every
    /// subsequent entry — that would be worse than crashing, because the trail
    /// would look healthy and be empty exactly when it mattered.
    func testRecordingRecoversIfTheFileIsDeletedUnderneath() {
        DiagnosticTrail.record("Persistence", "first")
        try? FileManager.default.removeItem(at: DiagnosticTrail.liveURL)

        DiagnosticTrail.record("Persistence", "second")
        DiagnosticTrail.record("Persistence", "third")

        let text = DiagnosticTrail.combinedText()
        XCTAssertTrue(text.contains("third"), "writer must reopen rather than go silent")
    }
}
