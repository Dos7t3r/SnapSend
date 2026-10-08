import Foundation
import UIKit
import CryptoKit

// One serial actor owns the library. Encoding, file writes and framing never run on the UI actor.
actor PhoneStorage {
    private let library: PhoneLibrary
    init(directory: URL) throws { library = try PhoneLibrary(directory: directory) }
    func snapshot() -> [PhonePhoto] { library.photos }
    func save(_ image: UIImage, context: LessonContext?, quality: Double, sendToAI: Bool = true) throws -> [PhonePhoto] {
        try autoreleasepool {
            guard let bytes = image.jpegData(compressionQuality: quality) else { throw PhoneLibrary.LibraryError.invalidSize }
            try library.save(bytes, context: context, sendToAI: sendToAI)
            return library.photos
        }
    }
    func save(_ data: Data, context: LessonContext?, quality: Double, sendToAI: Bool = true) throws -> [PhonePhoto] {
        try autoreleasepool {
            guard let image = UIImage(data: data) else { throw PhoneLibrary.LibraryError.invalidSize }
            return try save(image, context: context, quality: quality, sendToAI: sendToAI)
        }
    }
    func acknowledge(_ id: UUID) throws -> [PhonePhoto] { try library.acknowledge(id); return library.photos }
    func stage(_ id: UUID, _ stage: String, _ detail: String) throws -> [PhonePhoto] { try library.updateStage(id: id, stage: stage, detail: detail); return library.photos }
    func requeue(_ id: UUID) throws -> [PhonePhoto] { try library.requeue(id); return library.photos }
    func updateContext(_ context: LessonContext) throws -> [PhonePhoto] { try library.updateCourseName(from: context); return library.photos }
    func frame(_ photo: PhonePhoto) throws -> Data {
        let bytes = try Data(contentsOf: photo.url)
        guard bytes.count <= 40 * 1024 * 1024 else { throw PhoneLibrary.LibraryError.invalidSize }
        var header = WireHeader(kind: "photo", id: photo.id, byteCount: bytes.count,
                                sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        header.sendToAI = photo.sendToAI
        header.sessionID = photo.context?.lesson.id; header.capturedAt = photo.createdAt
        return try WireEncoder.encode(header, body: bytes)
    }
}
