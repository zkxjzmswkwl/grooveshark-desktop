import AppKit
import ImageIO
import SwiftUI

@MainActor
final class AlbumArtworkStore: ObservableObject {
    @Published private(set) var images: [String: NSImage] = [:]

    func image(for key: String) -> NSImage? {
        images[key]
    }

    func contains(key: String) -> Bool {
        images[key] != nil
    }

    func setImage(_ image: NSImage, for key: String) {
        guard images[key] !== image else { return }
        images[key] = image
    }

    func mergeImages(_ batch: [String: NSImage]) {
        guard !batch.isEmpty else { return }
        var next = images
        for (key, image) in batch {
            next[key] = image
        }
        images = next
    }
}

enum AlbumCoverImage {
    static func thumbnail(from data: Data, maxPixel: Int = 320) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return NSImage(data: data)
        }

        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return NSImage(data: data)
        }

        return NSImage(cgImage: cgImage, size: .zero)
    }
}
