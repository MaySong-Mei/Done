import XCTest
@testable import Done

final class AgenticIntakeAssetStoreTests: XCTestCase {
    func testSaveLoadAndRemoveAssets() throws {
        if ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil {
            throw XCTSkip("Known simulator host malloc crash occurs after this test completes on current local runtime.")
        }

        let fm = FileManager.default
        let baseDir = fm.temporaryDirectory.appendingPathComponent("AgenticIntakeAssetStoreTests-\(UUID().uuidString)", isDirectory: true)
        let expectedData = Data(repeating: 0xAB, count: 32)
        let store = AgenticIntakeAssetStore(
            fileManager: fm,
            baseDirectoryURL: baseDir,
            maxPixelDimension: 512,
            jpegQuality: 0.9,
            imageProcessor: { _ in (expectedData, CGSize(width: 120, height: 80)) }
        )
        let eventID = UUID()
        let inputData = Data(repeating: 0x11, count: 8)

        let refs = try store.saveImages([.init(data: inputData)], for: eventID)
        XCTAssertEqual(refs.count, 1)
        XCTAssertEqual(refs[0].pixelWidth, 120)
        XCTAssertEqual(refs[0].pixelHeight, 80)

        let savedURL = store.absoluteURL(for: refs[0])
        XCTAssertTrue(fm.fileExists(atPath: savedURL.path))
        XCTAssertEqual(try Data(contentsOf: savedURL), expectedData)

        let intake = AgenticIntakeRecord(rawText: "", images: refs, source: .quickAdd)
        store.removeAssets(for: intake)

        XCTAssertFalse(fm.fileExists(atPath: savedURL.path))
        try? fm.removeItem(at: baseDir)
    }
}
