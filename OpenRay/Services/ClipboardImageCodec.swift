import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct PreparedClipboardImage: Sendable {
    let image: ClipboardImage
    let png: Data
}

protocol ClipboardImagePreparing: Sendable {
    func prepare(_ data: Data) async throws -> PreparedClipboardImage
}

enum ClipboardImageCodec {
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func prepare(_ data: Data) throws -> PreparedClipboardImage {
        guard !data.isEmpty, data.count <= ClipboardLimits.sourceImageBytes else {
            throw LibraryValidationError("The copied image is too large. Source images are limited to 64 MB.")
        }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
            let dimensions = dimensions(of: source)
        else {
            throw LibraryValidationError("This clipboard image could not be read, or exceeds the 40-megapixel limit.")
        }
        let decodeOptions =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(dimensions.width, dimensions.height),
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, decodeOptions),
            let png = pngData(for: decoded), png.count <= ClipboardLimits.imageBytes
        else {
            throw LibraryValidationError("This image could not be saved as a PNG under the 10 MB per-image limit.")
        }
        let image = ClipboardImage(
            id: digest(png), pixelWidth: decoded.width, pixelHeight: decoded.height, byteCount: png.count)
        return PreparedClipboardImage(image: image, png: png)
    }

    static func thumbnail(_ resource: ClipboardImageResource, maxPixelSize: Int) -> Data? {
        guard resource.image.isValid else { return nil }
        let data: Data
        switch resource {
        case .unavailable: return nil
        case .memory(_, let png): data = png
        case .file(let image, let url):
            guard
                (try? url.deletingLastPathComponent().resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink)
                    != true
            else { return nil }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                values.isRegularFile == true, values.isSymbolicLink != true,
                values.fileSize == image.byteCount, let png = try? Data(contentsOf: url)
            else { return nil }
            data = png
        }
        guard data.count == resource.image.byteCount, digest(data) == resource.image.id,
            let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            dimensions(of: source) != nil
        else { return nil }
        let options =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, min(1_024, maxPixelSize)),
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return pngData(for: thumbnail)
    }

    private static func dimensions(of source: CGImageSource) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            width > 0, height > 0, width <= ClipboardLimits.imagePixels / height
        else { return nil }
        return (width, height)
    }

    private static func pngData(for image: CGImage) -> Data? {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return buffer as Data
    }
}

/// Image decoding/encoding is serialized off the main actor, and thumbnails are
/// bounded independently of the full-resolution clipboard image.
actor ClipboardImageProcessor: ClipboardImagePreparing {
    static let shared = ClipboardImageProcessor()
    private var thumbnails: [String: Data] = [:]
    private var order: [String] = []
    private var cachedBytes = 0

    func prepare(_ data: Data) throws -> PreparedClipboardImage {
        try Task.checkCancellation()
        let result = try ClipboardImageCodec.prepare(data)
        try Task.checkCancellation()
        return result
    }

    func thumbnail(_ resource: ClipboardImageResource, maxPixelSize: Int) -> Data? {
        guard !Task.isCancelled else { return nil }
        if case .unavailable = resource { return nil }
        let key = resource.image.id + ".\(maxPixelSize)"
        if let cached = thumbnails[key] { return cached }
        guard let data = ClipboardImageCodec.thumbnail(resource, maxPixelSize: maxPixelSize), !Task.isCancelled else {
            return nil
        }
        while order.count >= 80 || cachedBytes + data.count > 8_000_000, let oldest = order.first {
            order.removeFirst()
            cachedBytes -= thumbnails[oldest]?.count ?? 0
            thumbnails.removeValue(forKey: oldest)
        }
        guard data.count <= 8_000_000 else { return data }
        order.append(key)
        thumbnails[key] = data
        cachedBytes += data.count
        return data
    }

    func forget(_ identifiers: Set<String>) {
        for key in order where identifiers.contains(String(key.prefix(64))) {
            cachedBytes -= thumbnails[key]?.count ?? 0
            thumbnails.removeValue(forKey: key)
        }
        order.removeAll { identifiers.contains(String($0.prefix(64))) }
    }
}
