import Foundation
import UIKit

final class AgenticIntakeAssetStore {
    typealias ImageProcessor = (Data) throws -> (data: Data, size: CGSize)

    struct ImportedImage: Identifiable {
        let id: UUID
        let data: Data

        init(id: UUID = UUID(), data: Data) {
            self.id = id
            self.data = data
        }
    }

    private let fileManager: FileManager
    private let baseDirectoryURL: URL
    private let maxPixelDimension: CGFloat
    private let jpegQuality: CGFloat
    private let imageProcessor: ImageProcessor?

    init(
        fileManager: FileManager = .default,
        baseDirectoryURL: URL? = nil,
        maxPixelDimension: CGFloat = 2048,
        jpegQuality: CGFloat = 0.82,
        imageProcessor: ImageProcessor? = nil
    ) {
        self.fileManager = fileManager
        self.baseDirectoryURL = baseDirectoryURL ?? Self.defaultBaseDirectoryURL(fileManager: fileManager)
        self.maxPixelDimension = maxPixelDimension
        self.jpegQuality = jpegQuality
        self.imageProcessor = imageProcessor
    }

    func saveImages(_ images: [ImportedImage], for eventID: UUID) throws -> [AgenticIntakeImageRef] {
        guard !images.isEmpty else { return [] }
        let eventDirectory = baseDirectoryURL.appendingPathComponent(eventID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: eventDirectory, withIntermediateDirectories: true, attributes: nil)

        return try images.map { imported in
            let processed: (data: Data, size: CGSize)
            if let imageProcessor {
                processed = try imageProcessor(imported.data)
            } else {
                processed = try processedJPEG(from: imported.data)
            }
            let fileURL = eventDirectory.appendingPathComponent("\(imported.id.uuidString).jpg")
            try processed.data.write(to: fileURL, options: .atomic)
            let relativePath = eventID.uuidString + "/" + fileURL.lastPathComponent
            return AgenticIntakeImageRef(
                id: imported.id,
                relativePath: relativePath,
                pixelWidth: Int(processed.size.width.rounded()),
                pixelHeight: Int(processed.size.height.rounded()),
                fileSizeBytes: processed.data.count
            )
        }
    }

    func loadImage(for ref: AgenticIntakeImageRef) -> UIImage? {
        let url = absoluteURL(for: ref)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    func absoluteURL(for ref: AgenticIntakeImageRef) -> URL {
        baseDirectoryURL.appendingPathComponent(ref.relativePath)
    }

    func removeAssets(for intake: AgenticIntakeRecord) {
        removeAssets(for: intake.images)
    }

    func removeAssets(for refs: [AgenticIntakeImageRef]) {
        guard !refs.isEmpty else { return }
        for ref in refs {
            let url = absoluteURL(for: ref)
            try? fileManager.removeItem(at: url)
        }

        let parentDirs: Set<URL> = Set(refs.compactMap { ref in
            guard let slashIndex = ref.relativePath.lastIndex(of: "/") else { return nil }
            let parentRelativePath = String(ref.relativePath[..<slashIndex])
            return baseDirectoryURL.appendingPathComponent(parentRelativePath, isDirectory: true)
        })
        for dir in parentDirs {
            if let contents = try? fileManager.contentsOfDirectory(atPath: dir.path), contents.isEmpty {
                try? fileManager.removeItem(at: dir)
            }
        }
    }

    private func processedJPEG(from data: Data) throws -> (data: Data, size: CGSize) {
        guard let image = UIImage(data: data) else {
            throw AssetStoreError.invalidImageData
        }
        let resized = resizeIfNeeded(image)
        guard let jpeg = resized.jpegData(compressionQuality: jpegQuality) else {
            throw AssetStoreError.encodingFailed
        }
        return (jpeg, resized.size)
    }

    private func resizeIfNeeded(_ image: UIImage) -> UIImage {
        let size = image.size
        let maxDimension = max(size.width, size.height)
        guard maxDimension.isFinite, maxDimension > maxPixelDimension, maxPixelDimension > 0 else {
            return image
        }

        let scale = maxPixelDimension / maxDimension
        let targetSize = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private static func defaultBaseDirectoryURL(fileManager: FileManager) -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return appSupport.appendingPathComponent("AgenticIntakeAssets", isDirectory: true)
    }

    enum AssetStoreError: LocalizedError {
        case invalidImageData
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .invalidImageData:
                return "Invalid image data"
            case .encodingFailed:
                return "Failed to encode image"
            }
        }
    }
}
