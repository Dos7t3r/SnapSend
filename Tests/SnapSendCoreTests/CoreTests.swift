import XCTest
import CryptoKit
@testable import SnapSendCore

final class CoreTests: XCTestCase {
    func testConversationURLIncludesProjectChatsButRejectsLandingPages() {
        XCTAssertTrue(ChatURL.isConversation("https://chatgpt.com/c/6ac67d7c-1698-83ea-9d8f-d46c60b2ac0c"))
        XCTAssertTrue(ChatURL.isConversation("https://chatgpt.com/g/g-p-example-sta256/c/6ac67d7c-1698-83ea-9d8f-d46c60b2ac0c"))
        XCTAssertTrue(ChatURL.isConversation("https://chatgpt.com/g/custom-gpt/c/chat-id/?model=auto"))
        for url in ["https://chatgpt.com/g/g-p-example-sta256", "https://chatgpt.com/c/", "https://chatgpt.com/foo/c/chat", "https://example.com/c/chat", "http://chatgpt.com/c/chat", "https://chatgpt.com/c/chat/extra", "https://user@chatgpt.com/c/chat"] {
            XCTAssertFalse(ChatURL.isConversation(url), url)
        }
    }

    func testDeliveryRecoveryDoesNotRepeatInterruptedOrSentPhotos() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = try DeliveryLedger(directory: dir)
        let lesson = UUID(), first = UUID(), second = UUID()
        try ledger.enqueue(id: first, lessonID: lesson, destination: "chrome")
        try ledger.enqueue(id: first, lessonID: UUID(), destination: "native")
        XCTAssertEqual(ledger.entries.count, 1)
        XCTAssertThrowsError(try ledger.transition(id: first, state: .sent, detail: "invalid"))
        try ledger.transition(id: first, state: .preparing, detail: "uploading")
        try ledger.transition(id: first, state: .submitting, detail: "sending")
        try ledger.enqueue(id: second, lessonID: lesson, destination: "chrome")
        try ledger.transition(id: second, state: .preparing, detail: "uploading")
        try ledger.transition(id: second, state: .submitting, detail: "sending")
        try ledger.transition(id: second, state: .sent, detail: "confirmed")
        let restored = try DeliveryLedger(directory: dir)
        XCTAssertEqual(restored.entries[0].state, .uncertain)
        XCTAssertEqual(restored.entries[1].state, .sent)
        XCTAssertThrowsError(try restored.transition(id: second, state: .queued, detail: "duplicate"))
        try restored.transition(id: first, state: .queued, detail: "user verified not sent")
        XCTAssertEqual(try DeliveryLedger(directory: dir).entries[0].state, .queued)
    }

    func testShortCodeExpirationAttemptLimitAndDeviceProof() throws {
        let now = Date()
        var code = PairingChallenge(code: "012345", now: now)
        XCTAssertFalse(code.verify("wrong", now: now))
        XCTAssertTrue(code.verify("012345", now: now))
        XCTAssertFalse(code.verify("012345", now: now))
        var exhausted = PairingChallenge(code: "012345", now: now)
        for _ in 0..<3 { XCTAssertFalse(exhausted.verify("000000", now: now)) }
        XCTAssertFalse(exhausted.verify("012345", now: now))
        var expired = PairingChallenge(code: "012345", now: now)
        XCTAssertFalse(expired.verify("012345", now: now.addingTimeInterval(61)))
        let secret = try PairingCrypto.secret()
        let proof = PairingCrypto.proof(secret: secret, challenge: "fresh challenge")
        XCTAssertTrue(PairingCrypto.matches(proof, secret: secret, challenge: "fresh challenge"))
        XCTAssertFalse(PairingCrypto.matches(proof, secret: secret, challenge: "another challenge"))
    }
    func testClassIsolationAndOfflineCaptureContextSurviveRestart() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try PhotoStore(directory: dir.appendingPathComponent("mac"))
        let first = try store.createCourse(name: "高数", now: Date(timeIntervalSince1970: 100))
        let originalContext = try XCTUnwrap(store.context(for: first.id))
        let phone = try PhoneLibrary(directory: dir.appendingPathComponent("phone"))
        let photoID = try phone.save(Data([1, 2]), context: originalContext)
        let next = try store.startLesson(courseID: first.courseID, now: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(store.catalog.activeLessonID, next.id)
        let restored = try PhoneLibrary(directory: phone.directory)
        XCTAssertEqual(restored.photos.first?.context?.lesson.id, first.id)
        try store.save(Data([1, 2]), id: photoID, sessionID: restored.photos.first?.context?.lesson.id)
        let reloaded = try PhotoStore(directory: store.directory)
        XCTAssertEqual(reloaded.records.first?.sessionID, first.id)
        XCTAssertTrue(reloaded.records.first!.filename.contains(first.id.uuidString))
        XCTAssertThrowsError(try store.save(Data([3]), sessionID: UUID()))
        try store.renameCourse(first.courseID, name: "数学")
        XCTAssertEqual(store.context(for: next.id)?.courseName, "数学")
        try phone.acknowledge(photoID); try phone.requeue(photoID)
        XCTAssertEqual(try PhoneLibrary(directory: phone.directory).photos.first?.receivedByMac, false)
    }
    func testLegacyFlatArchiveMigratesWithoutMovingOrLosingPhotos() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID(), filename = "\(id.uuidString).jpg"
        let bytes = Data([1, 2])
        try bytes.write(to: dir.appendingPathComponent(filename))
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let old: [[String: Any]] = [["id": id.uuidString, "receivedAt": 100.0, "filename": filename,
                                    "sha256": hash, "byteCount": 2, "status": "Mac 已保存"]]
        try JSONSerialization.data(withJSONObject: old).write(to: dir.appendingPathComponent("photos.json"))
        let store = try PhotoStore(directory: dir)
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records.first?.filename, filename)
        XCTAssertEqual(store.records.first?.sessionID, store.catalog.legacyLessonID)
        XCTAssertEqual(try Data(contentsOf: store.url(for: store.records[0])), bytes)
        XCTAssertEqual(try PhotoStore(directory: dir).catalog.courses.count, 1)
    }
    func testPhoneHistoryRestoresLegacyPhotosAndDurableReceipts() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let oldID = UUID()
        let oldFile = dir.appendingPathComponent("\(oldID.uuidString).jpg")
        try Data([1, 2, 3]).write(to: oldFile)
        let library = try PhoneLibrary(directory: dir)
        XCTAssertEqual(library.photos.first?.id, oldID)
        XCTAssertEqual(library.photos.first?.receivedByMac, false)
        try library.acknowledge(oldID)
        let restored = try PhoneLibrary(directory: dir)
        XCTAssertEqual(restored.photos.first?.receivedByMac, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldFile.path))
        let newID = try restored.save(Data([4, 5, 6]))
        let afterRestart = try PhoneLibrary(directory: dir)
        XCTAssertEqual(afterRestart.photos.count, 2)
        XCTAssertEqual(afterRestart.photos.first { $0.id == newID }?.receivedByMac, false)
        XCTAssertThrowsError(try restored.acknowledge(UUID()))
    }
    func testHandshakeAndPhotoCanArriveTogether() throws {
        let ready = try WireEncoder.encode(WireHeader(kind: "ready", id: UUID(), byteCount: 0, sha256: ""))
        let body = Data([3, 4])
        let photo = try WireEncoder.encode(WireHeader(kind: "photo", id: UUID(), byteCount: 2, sha256: "test"), body: body)
        var decoder = WireDecoder()
        let decoded = try decoder.append(ready + photo)
        XCTAssertEqual(decoded.map { $0.0.kind }, ["ready", "photo"])
        XCTAssertEqual(decoded.last?.1, body)
        XCTAssertThrowsError(try WireEncoder.encode(WireHeader(kind: "photo", id: UUID(), byteCount: 2, sha256: "")))
    }
    func testDurableDeduplicationAndHashValidation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try PhotoStore(directory: dir)
        let id = UUID(), data = Data([1, 2, 3])
        try store.save(data, id: id)
        try store.save(data, id: id)
        XCTAssertEqual(try PhotoStore(directory: dir).records.count, 1)
        XCTAssertThrowsError(try store.save(Data([4]), id: id))
        XCTAssertThrowsError(try store.save(data, expectedHash: "incorrect"))
    }
    func testFragmentedBinaryFrameAndSizeLimit() throws {
        let photo = Data([0, 1, 2, 255])
        let hash = SHA256.hash(data: photo).map { String(format: "%02x", $0) }.joined()
        let meta = try JSONEncoder().encode(WireHeader(kind: "photo", id: UUID(), byteCount: photo.count, sha256: hash))
        let count = UInt32(meta.count)
        var frame = Data([UInt8((count >> 24) & 255), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)])
        frame.append(meta); frame.append(photo)
        var decoder = WireDecoder()
        for byte in frame.dropLast() { XCTAssertTrue(try decoder.append(Data([byte])).isEmpty) }
        XCTAssertEqual(try decoder.append(Data([frame.last!])).first?.1, photo)
        var bad = WireDecoder()
        XCTAssertThrowsError(try bad.append(Data([255, 255, 255, 255])))
    }

    func testPhotoStageTrackingAndPersistence() throws {
        XCTAssertEqual(SnapSendVersion, "0.5.0")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = try PhoneLibrary(directory: dir)
        let id = try library.save(Data([1, 2, 3]))
        XCTAssertNil(library.photos.first?.stage)
        try library.updateStage(id: id, stage: "received", detail: "Mac 已归档")
        XCTAssertEqual(library.photos.first?.stage, "received")
        XCTAssertEqual(library.photos.first?.stageDetail, "Mac 已归档")
        try library.updateStage(id: id, stage: "sent", detail: "AI 已接收")
        let restored = try PhoneLibrary(directory: dir)
        XCTAssertEqual(restored.photos.first?.stage, "sent")
        XCTAssertEqual(restored.photos.first?.stageDetail, "AI 已接收")
    }

    func testStoreBatchOperationsAndLedgerManagement() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try PhotoStore(directory: dir)
        let lesson = try store.createCourse(name: "数学课")
        let photo1 = try store.save(Data([1, 2, 3, 4]), sessionID: lesson.id)
        let photo2 = try store.save(Data([5, 6, 7, 8]), sessionID: lesson.id)
        XCTAssertEqual(store.records.count, 2)
        XCTAssertGreaterThan(store.calculateStorageBytes(), 0)

        let ledger = try DeliveryLedger(directory: dir)
        try ledger.forceEnqueue(id: photo1.id, lessonID: lesson.id, destination: "chrome")
        try ledger.forceEnqueue(id: photo2.id, lessonID: lesson.id, destination: "chrome")
        XCTAssertEqual(ledger.entries.count, 2)

        try store.delete(ids: [photo1.id])
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records.first?.id, photo2.id)

        try ledger.remove(ids: [photo1.id])
        XCTAssertEqual(ledger.entries.count, 1)
        XCTAssertEqual(ledger.entries.first?.id, photo2.id)
    }
    func testQueueManagementCannotDiscardAnActiveSend() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = try DeliveryLedger(directory: dir), id = UUID(), lesson = UUID()
        try ledger.enqueue(id: id, lessonID: lesson, destination: "chrome")
        try ledger.transition(id: id, state: .preparing, detail: "uploading")
        XCTAssertThrowsError(try ledger.forceEnqueue(id: id, lessonID: lesson, destination: "chrome"))
        XCTAssertThrowsError(try ledger.remove(ids: [id]))
        XCTAssertThrowsError(try ledger.resetQueue())
        XCTAssertEqual(ledger.entries.first?.state, .preparing)
        try ledger.transition(id: id, state: .submitting, detail: "sending")
        XCTAssertThrowsError(try ledger.forceEnqueue(id: id, lessonID: lesson, destination: "chrome"))
        try ledger.transition(id: id, state: .sent, detail: "confirmed")
        XCTAssertThrowsError(try ledger.forceEnqueue(id: id, lessonID: UUID(), destination: "chrome"))
    }

    func testFailedDeleteManifestWritePreservesOriginals() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try PhotoStore(directory: dir)
        let photo = try store.save(Data([1, 2, 3]))
        let manifest = dir.appendingPathComponent("photos.json")
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: true)
        try Data([1]).write(to: manifest.appendingPathComponent("blocker"))
        XCTAssertThrowsError(try store.delete(ids: [photo.id]))
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(try Data(contentsOf: store.url(for: photo)), Data([1, 2, 3]))
    }

    func testCourseTrashRestoreAndPhotoMigrationPersist() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try PhotoStore(directory: dir)
        let source = try store.createCourse(name: "Source")
        let photo = try store.save(Data([1,2,3]), sessionID: source.id)
        let oldURL = store.url(for: photo)
        let target = try store.createCourse(name: "Target")
        try store.renameLesson(target.id, title: "Week 2")
        try store.movePhotos(ids: [photo.id], to: target.id)
        let moved = try XCTUnwrap(store.records.first)
        XCTAssertEqual(moved.sessionID, target.id)
        XCTAssertEqual(try Data(contentsOf: store.url(for: moved)), Data([1,2,3]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        try store.archiveCourse(target.courseID, archived: true)
        XCTAssertNil(store.catalog.activeLessonID)
        XCTAssertThrowsError(try store.activateLesson(target.id))
        XCTAssertThrowsError(try store.startLesson(courseID: target.courseID))
        XCTAssertThrowsError(try store.movePhotos(ids: [photo.id], to: target.id))
        let restored = try PhotoStore(directory: dir)
        XCTAssertEqual(restored.records.first?.sessionID, target.id)
        XCTAssertEqual(restored.catalog.context(for: target.id)?.lesson.title, "Week 2")
        try restored.archiveCourse(target.courseID, archived: false)
        XCTAssertEqual(restored.catalog.courses.first(where: { $0.id == target.courseID })?.archived, false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.url(for: moved).path))
    }
    func testPhotoMigrationManifestFailureKeepsSource() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try PhotoStore(directory: dir), source = try store.createCourse(name: "A")
        let photo = try store.save(Data([3,4]), sessionID: source.id)
        let target = try store.createCourse(name: "B")
        let manifest = dir.appendingPathComponent("photos.json")
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: true)
        try Data([1]).write(to: manifest.appendingPathComponent("blocker"))
        XCTAssertThrowsError(try store.movePhotos(ids: [photo.id], to: target.id))
        XCTAssertEqual(store.records.first?.sessionID, source.id)
        XCTAssertEqual(try Data(contentsOf: store.url(for: photo)), Data([3,4]))
    }
    func testPhoneStatusUpdatesDoNotRescanUnrelatedDirectoryEntries() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = try PhoneLibrary(directory: dir), id = try library.save(Data([1]))
        let extra = dir.appendingPathComponent(UUID().uuidString + ".jpg")
        try Data([2]).write(to: extra)
        try library.updateStage(id: id, stage: "sent", detail: "confirmed")
        XCTAssertEqual(library.photos.count, 1)
        try library.acknowledge(id)
        XCTAssertTrue(library.photos.first?.receivedByMac == true)
        XCTAssertEqual(try PhoneLibrary(directory: dir).photos.count, 2)
    }

}
