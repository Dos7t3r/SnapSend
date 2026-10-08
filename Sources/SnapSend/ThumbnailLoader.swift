import Foundation
import ImageIO
import CoreGraphics

// Decoding runs on this actor's executor, never on the UI actor. Cache is bounded by decoded bytes.
actor ThumbnailLoader {
    static let shared = ThumbnailLoader()
    private let cache = NSCache<NSString, CGImage>()
    init() { cache.totalCostLimit = 24 * 1024 * 1024; cache.countLimit = 48 }
    func load(_ url: URL, pixels: Int = 480) -> CGImage? {
        let key = "\(url.path):\(pixels)" as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0,
                [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                 kCGImageSourceThumbnailMaxPixelSize: pixels, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        cache.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }
    func clear() { cache.removeAllObjects() }
}
