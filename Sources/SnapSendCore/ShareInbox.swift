import Foundation
import CryptoKit

/// Extension-private outbox. Files precede manifest commit; UUIDs survive retries.
public struct SharedImage: Codable, Identifiable, Sendable {
    public let id: UUID
    public let filename: String
    public let byteCount: Int
    public let sha256: String
    public let createdAt: Date
}

public enum ShareFile {
    public static let limit = 20 * 1024 * 1024
    public static let chunkSize = 256 * 1024
    public static func inspect(_ url: URL) throws -> (count: Int, hash: String, suffix: String) {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let signature = try handle.read(upToCount: 8) ?? Data()
        let suffix: String
        if signature.starts(with: [137,80,78,71,13,10,26,10]) { suffix = "png" }
        else if signature.starts(with: [255,216,255]) { suffix = "jpg" }
        else { throw Failure.unsupported }
        try handle.seek(toOffset: 0)
        var hash = SHA256(), count = 0
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            count += chunk.count; guard count <= limit else { throw Failure.tooLarge }
            hash.update(data: chunk)
        }
        guard count > 0 else { throw Failure.unsupported }
        return (count, hash.finalize().map { String(format: "%02x", $0) }.joined(), suffix)
    }
    public enum Failure: LocalizedError {
        case unsupported, tooLarge, budget, changed
        public var errorDescription: String? {
            switch self {
            case .unsupported: return "首版支持 PNG 和 JPEG 图片，请以图片格式分享。"
            case .tooLarge: return "单张图片不能超过 20MB。原图仍在来源 App。"
            case .budget: return "待传图片已超过 100MB，请先重试传输或删除待传图片。"
            case .changed: return "待传原图已变化，请重新分享。"
            }
        }
    }
}

public final class ShareInbox {
    public let directory: URL
    public private(set) var items: [SharedImage]
    private var manifest: URL { directory.appendingPathComponent("shares.json") }
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("shares.json")
        items = FileManager.default.fileExists(atPath: file.path) ? try JSONDecoder().decode([SharedImage].self, from: Data(contentsOf: file)) : []
        // Remove interrupted, uncommitted copies; never remove manifest-backed pending originals.
        let known = Set(items.map(\.filename))
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where ["png", "jpg"].contains(url.pathExtension) && !known.contains(url.lastPathComponent) {
            try FileManager.default.removeItem(at: url)
        }
    }
    @discardableResult public func add(_ source: URL) throws -> SharedImage {
        let info = try ShareFile.inspect(source)
        guard items.reduce(0, { $0 + $1.byteCount }) + info.count <= 100 * 1024 * 1024 else { throw ShareFile.Failure.budget }
        let id = UUID(), name = "\(UUID().uuidString).\(info.suffix)"
        let item = SharedImage(id: id, filename: name, byteCount: info.count, sha256: info.hash, createdAt: Date())
        let target = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: target)
        do {
            let copied = try ShareFile.inspect(target)
            guard copied.hash == info.hash, copied.count == info.count else { throw ShareFile.Failure.changed }
            let next = items + [item]; try JSONEncoder().encode(next).write(to: manifest, options: .atomic); items = next
        } catch { try? FileManager.default.removeItem(at: target); throw error }
        return item
    }
    public func url(_ item: SharedImage) -> URL { directory.appendingPathComponent(item.filename) }
    public func remove(_ id: UUID) throws {
        let old = items.first { $0.id == id }
        let next = items.filter { $0.id != id }
        try JSONEncoder().encode(next).write(to: manifest, options: .atomic); items = next
        if let old { try? FileManager.default.removeItem(at: url(old)) }
    }
}
