import Foundation

public let SnapSendVersion = "0.6.2"

/// 4-byte big-endian metadata length, JSON metadata, then binary image bytes.
public struct WireHeader: Codable, Sendable {
    public let version: Int
    public let kind: String
    public let id: UUID
    public let byteCount: Int
    public let sha256: String
    public var deviceID: UUID?
    public var challenge: String?
    public var secret: String?
    public var message: String?
    public var sessionID: UUID?
    public var capturedAt: Date?
    public var capabilities: [String]?
    public var deliveryIntent: String?
    public var sendToAI: Bool? // nil preserves compatibility with older phones
    public init(kind: String, id: UUID = UUID(), byteCount: Int = 0, sha256: String = "") {
        version = 2; self.kind = kind; self.id = id; self.byteCount = byteCount; self.sha256 = sha256
    }
}

public struct WireDecoder {
    private var buffer = Data()
    public init() {}
    public mutating func append(_ data: Data) throws -> [(WireHeader, Data)] {
        buffer.append(data)
        guard buffer.count <= 41 * 1024 * 1024 else { throw WireError.tooLarge }
        var output: [(WireHeader, Data)] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
            guard (1...4096).contains(length) else { throw WireError.invalidHeader }
            guard buffer.count >= 4 + length else { break }
            let header = try JSONDecoder().decode(WireHeader.self, from: buffer.subdata(in: 4..<(4 + length)))
            let photo = header.kind == "photo" && (1...(40 * 1024 * 1024)).contains(header.byteCount)
            let control = ["ready", "hello", "pairing", "paired", "failure"].contains(header.kind) && header.byteCount == 0
            guard header.version == 2, photo || control else {
                throw WireError.invalidHeader
            }
            let end = 4 + length + header.byteCount
            guard buffer.count >= end else { break }
            output.append((header, buffer.subdata(in: (4 + length)..<end)))
            buffer = Data(buffer.dropFirst(end))
        }
        return output
    }
    public enum WireError: Error { case tooLarge, invalidHeader }
}

public enum WireEncoder {
    public static func metadata(_ header: WireHeader) throws -> Data {
        let metadata = try JSONEncoder().encode(header)
        guard metadata.count <= 4096 else { throw WireDecoder.WireError.invalidHeader }
        let length = UInt32(metadata.count)
        var result = Data([UInt8((length >> 24) & 255), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)])
        result.append(metadata); return result
    }
    public static func encode(_ header: WireHeader, body: Data = Data()) throws -> Data {
        guard header.byteCount == body.count else { throw WireDecoder.WireError.invalidHeader }
        var result = try metadata(header)
        result.append(body)
        return result
    }
}
