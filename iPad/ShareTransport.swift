import Foundation
import Network
import ImageIO

/// Sends one chunk at a time. At most one 256KB image buffer is outstanding.
actor ShareTransport {
    func send(_ image: SharedImage, at url: URL, session: UUID?, over connection: NWConnection) async throws {
        let info = try ShareFile.inspect(url)
        guard info.count == image.byteCount, info.hash == image.sha256 else { throw ShareFile.Failure.changed }
        var header = WireHeader(kind: "photo", id: image.id, byteCount: image.byteCount, sha256: image.sha256)
        header.sendToAI = false; header.sessionID = session; header.capturedAt = image.createdAt
        try await write(try WireEncoder.metadata(header), to: connection)
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var sent = 0
        while let chunk = try file.read(upToCount: ShareFile.chunkSize), !chunk.isEmpty {
            try Task.checkCancellation(); sent += chunk.count
            guard sent <= image.byteCount else { throw ShareFile.Failure.changed }
            try await write(chunk, to: connection)
        }
        guard sent == image.byteCount else { throw ShareFile.Failure.changed }
    }
    private func write(_ data: Data, to connection: NWConnection) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}

actor ShareStorage {
    private let inbox: ShareInbox
    init(directory: URL) throws { inbox = try ShareInbox(directory: directory) }
    func snapshot() -> [SharedImage] { inbox.items }
    func add(_ source: URL) throws -> SharedImage {
        guard let image = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache:false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(image,0,nil) as? [CFString:Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16000, height <= 16000, width * height <= 100_000_000 else { throw ShareFile.Failure.unsupported }
        return try inbox.add(source)
    }
    func url(_ image: SharedImage) -> URL { inbox.url(image) }
    func remove(_ id: UUID) throws { try inbox.remove(id) }
}
