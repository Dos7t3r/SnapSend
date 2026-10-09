import XCTest
import SwiftUI
import UIKit
import Network
import CryptoKit

final class ShareTests: XCTestCase {
    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true); return path
    }
    private func png() -> Data {
        let renderer = UIGraphicsImageRenderer(size:CGSize(width:32,height:24))
        return renderer.pngData { ctx in UIColor.systemBlue.setFill(); ctx.fill(CGRect(x:0,y:0,width:32,height:24)) }
    }
    func testArchivePreservesPNGAndRetryIdentity() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at:folder) }
        let source = folder.appendingPathComponent("source.png"), bytes = png(); try bytes.write(to:source)
        let inbox = try ShareInbox(directory:folder.appendingPathComponent("pending"))
        let item = try inbox.add(source)
        XCTAssertEqual(try Data(contentsOf:inbox.url(item)),bytes)
        XCTAssertEqual(item.sha256,SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined())
        let reloaded = try ShareInbox(directory:inbox.directory)
        XCTAssertEqual(reloaded.items.first?.id,item.id)
        try reloaded.remove(item.id); XCTAssertTrue(reloaded.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath:inbox.url(item).path)); XCTAssertTrue(FileManager.default.fileExists(atPath:source.path))
    }
    func testRejectUnsupportedAndOversizeWithoutPendingEntry() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at:folder) }
        let inbox = try ShareInbox(directory:folder.appendingPathComponent("pending"))
        let source = folder.appendingPathComponent("source")
        try Data("not an image".utf8).write(to:source); XCTAssertThrowsError(try inbox.add(source))
        var large = Data([137,80,78,71,13,10,26,10]); large.append(Data(repeating:0,count:ShareFile.limit))
        try large.write(to:source); XCTAssertThrowsError(try inbox.add(source)); XCTAssertTrue(inbox.items.isEmpty)
    }
    func testStreamingMetadataIsWireCompatible() throws {
        let data = png()
        var header = WireHeader(kind:"photo",byteCount:data.count); header.sendToAI = false
        var decoder = WireDecoder(); XCTAssertTrue(try decoder.append(WireEncoder.metadata(header)).isEmpty)
        let result = try decoder.append(data)
        XCTAssertEqual(result.count,1); XCTAssertEqual(result[0].1,data); XCTAssertEqual(result[0].0.sendToAI,false)
    }
    func testInterruptedUncommittedFileCleanupPreservesPending() throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at:folder) }
        let source = folder.appendingPathComponent("source.png"); try png().write(to:source)
        let inbox = try ShareInbox(directory:folder.appendingPathComponent("pending")); let item = try inbox.add(source)
        let stray = inbox.directory.appendingPathComponent("interrupted.png"); try png().write(to:stray)
        let restored = try ShareInbox(directory:inbox.directory)
        XCTAssertEqual(restored.items.first?.id,item.id); XCTAssertTrue(FileManager.default.fileExists(atPath:restored.url(item).path)); XCTAssertFalse(FileManager.default.fileExists(atPath:stray.path))
    }
}

extension ShareTests {
    @MainActor func testSystemProviderPairingAndArchiveReceipt() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at:folder) }
        let bytes = png(), url = folder.appendingPathComponent("image.png"); try bytes.write(to:url)
        let item = NSExtensionItem(); item.attachments = [try XCTUnwrap(NSItemProvider(contentsOf:url))]
        var credentials: [String:String] = [:]
        let model = ShareModel(directory:folder.appendingPathComponent("pending"),loadPairings:{ credentials },savePairings:{ credentials = $0 }); defer { model.stop() }
        model.start(items:[item]); try await waitUntil { !model.importing }
        try XCTUnwrap(model.preview); XCTAssertNil(model.error); XCTAssertFalse(model.images.isEmpty)
        let conn = NWConnection(host:"127.0.0.1",port:27184,using:.tcp); defer { conn.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: conn.stateUpdateHandler = nil; continuation.resume()
                case .failed(let error): conn.stateUpdateHandler = nil; continuation.resume(throwing:error)
                default:break
                }
            }; conn.start(queue:.main)
        }
        let peer = UUID(), name = Data("QA Mac".utf8).base64EncodedString()
        try await command("HELLO \(peer.uuidString) \(name)",conn)
        try await waitUntil { model.pairingCode != nil }
        try await command("PAIR \(try XCTUnwrap(model.pairingCode))",conn)
        try await waitUntil { model.connected }
        try await command("CONTEXT -",conn)
        try await waitUntil { model.status == "已连接 · 可以保存到 Mac" }
        model.beginTransfer()
        var decoder = WireDecoder(), photo: (WireHeader,Data)?
        while photo == nil {
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                conn.receive(minimumIncompleteLength:1,maximumLength:ShareFile.chunkSize) { data,_,done,error in
                    if let error { continuation.resume(throwing:error) }
                    else if let data, !data.isEmpty { continuation.resume(returning:data) }
                    else { continuation.resume(throwing:ShareFile.Failure.changed) }
                }
            }
            for frame in try decoder.append(data) where frame.0.kind == "photo" { photo = frame }
        }
        let result = try XCTUnwrap(photo)
        XCTAssertEqual(result.1,bytes); XCTAssertEqual(result.0.sendToAI,false)
        XCTAssertEqual(result.0.sha256,SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined())
        XCTAssertTrue(model.transferring); XCTAssertEqual(model.completed,0) // Socket write is not an archive receipt.
        try await command("RECEIVED \(result.0.id.uuidString)",conn)
        try await waitUntil { model.completed == 1 && !model.transferring }
        XCTAssertTrue(model.images.isEmpty)
        XCTAssertEqual(model.status,"已保存到 Mac · 本次不自动发送 AI")
    }
    @MainActor private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 { if predicate() { return }; try await Task.sleep(for:.milliseconds(100)) }
        XCTFail("Timed out waiting for protocol event"); throw ShareFile.Failure.changed
    }
    private func command(_ line:String,_ conn:NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
            conn.send(content:Data((line+"\n").utf8),completion:.contentProcessed { error in
                if let error { continuation.resume(throwing:error) } else { continuation.resume() }
            })
        }
    }
    @MainActor func testPanelRendersWithoutCameraAndLargeDecodedImage() throws {
        let model = ShareModel()
        let host = UIHostingController(rootView:SharePanel(model:model,finish:{}))
        host.view.frame = CGRect(x:0,y:0,width:540,height:640); host.view.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(size:host.view.bounds.size)
        let image = renderer.image { _ in host.view.drawHierarchy(in:host.view.bounds,afterScreenUpdates:true) }
        let attachment = XCTAttachment(image:image); attachment.name = "iPad Share waiting"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertEqual(host.view.bounds.width,540)
        model.stop()
    }
}
