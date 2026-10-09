import SwiftUI
import AppKit
import SnapSendCore

@main struct WorkspaceIntegration {
    static func check(_ value: @autoclosure () -> Bool, line: UInt = #line) {
        guard value() else { FileHandle.standardError.write(Data("FAIL: workspace assertion at line \(line)\n".utf8)); fatalError("Workspace assertion \(line)") }
    }
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PhotoStore(directory: root)
        let model = WorkspaceModel(preview: true)
        try model.configurePreview(store: store, sending: false)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: "assets/brand/SnapMark.png"))
        try model.receive(bytes)
        check(model.usbConnected && model.inboxPhotos.count == 1 && model.catalog.activeLessonID == nil)
        let firstPhoto = model.records[0].id
        model.autoSendPromptOnStartLesson = false
        model.createCourse("STA256")
        let section = model.targetSection!.id
        model.autoSendPromptOnStartLesson = false
        let url = "https://chatgpt.com/g/g-p-sta256/c/integration-chat"
        check(model.browserCommand(["kind": "bind", "url": url, "tab": 7])["ok"] as? Bool == true)
        check(store.catalog.sections?.first?.chatURL == url && !model.autoSend)
        model.assignPhotos([firstPhoto], to: section, send: true)
        check(model.deliveries.first?.state == .queued && !model.autoSend)
        let poll = model.browserCommand(["kind": "poll", "url": url, "tab": 7])
        check(poll["id"] as? String == firstPhoto.uuidString && poll["jpeg"] != nil)
        let active = model.catalog.activeLessonID
        model.chooseSection(nil); model.createCourse("Do not switch while sending")
        check(model.catalog.activeLessonID == active && model.catalog.courses.filter { $0.name == "Do not switch while sending" }.isEmpty)
        check(model.browserCommand(["kind": "submitting", "url": url, "tab": 7, "id": firstPhoto.uuidString])["ok"] as? Bool == true)
        check(model.browserCommand(["kind": "result", "url": url, "tab": 7, "id": firstPhoto.uuidString, "state": "sent"])["ok"] as? Bool == true)
        check(model.deliveries.first?.state == .sent)
        // Paused intake is durable save-only; enabling never backfills it.
        model.pauseDelivery()
        try model.receive(bytes)
        let savedOnly = model.records.last!
        check(model.stageOf(savedOnly) == .held)
        model.enableDelivery()
        check(model.autoSend && model.stageOf(savedOnly) == .held)
        var personal = WireHeader(kind: "photo", byteCount: bytes.count, sha256: model.records[0].sha256)
        personal.sendToAI = false
        try model.receive(bytes, header: personal)
        let personalPhoto = model.records.first { $0.id == personal.id }!
        check(model.stageOf(personalPhoto) == .held)
        try model.receive(bytes)
        let queued = model.records.last!
        check(model.stageOf(queued) == .queued)
        model.sendSinglePhotoToAI(savedOnly)
        check(!model.autoSend)
        let one = model.browserCommand(["kind":"poll","url":url,"tab":7])
        check(one["id"] as? String == savedOnly.id.uuidString)
        _ = model.browserCommand(["kind":"submitting","url":url,"tab":7,"id":savedOnly.id.uuidString])
        _ = model.browserCommand(["kind":"result","url":url,"tab":7,"id":savedOnly.id.uuidString,"state":"sent"])
        let noDrain = model.browserCommand(["kind":"poll","url":url,"tab":7])
        check(noDrain["id"] == nil && model.stageOf(queued) == .queued)
        model.holdPhoto(queued)
        model.enableDelivery()
        let todayArchive = model.boundLesson
        model.resolveTarget(now: Calendar.current.date(byAdding: .day, value: 1, to: Date())!)
        check(model.boundLesson != todayArchive && model.autoSend && model.boundChat == url)
        check(model.browserCommand(["kind": "status", "url": url, "tab": 7])["matching"] as? Bool == true)
        // Retry of the same USB ID must not duplicate a delivery or relocate its archive.
        let header = WireHeader(kind: "photo", id: firstPhoto, byteCount: bytes.count, sha256: model.records[0].sha256)
        try model.receive(bytes, header: header)
        check(model.records.count == 4 && model.deliveries.count == 4 && model.stageOf(model.records.first { $0.id == firstPhoto }!) == .sent)
        let restored = WorkspaceModel(preview: true)
        try restored.configurePreview(store: PhotoStore(directory: root), sending: false)
        check(restored.chatMatchesClass && restored.boundChat == url)
        check(restored.stageOf(restored.records[0]) == .sent)
        check(restored.browserCommand(["kind":"restore","section":section.uuidString,"url":"https://chatgpt.com/c/wrong","tab":9])["ok"] as? Bool == false)
        check(restored.browserCommand(["kind":"restore","section":section.uuidString,"url":url,"tab":9])["ok"] as? Bool == true)
        check(restored.browserCommand(["kind":"status","url":url,"tab":9])["matching"] as? Bool == true)
        // A late draft never attached a photo: safely defer and retry the same UUID.
        restored.enableDelivery()
        try restored.receive(bytes)
        let recoverable = restored.records.last!
        check(restored.browserCommand(["kind":"poll","url":url,"tab":9])["id"] as? String == recoverable.id.uuidString)
        restored.refreshBrowserPresence(now:Date().addingTimeInterval(60))
        check(restored.autoSend) // Bounded upload lease outlives the 45-second idle heartbeat.
        check(restored.browserCommand(["kind":"defer","url":url,"tab":9,"id":recoverable.id.uuidString,"detail":"等待：有草稿"])["ok"] as? Bool == true)
        check(restored.stageOf(recoverable) == .queued && restored.autoSend)
        check(restored.browserCommand(["kind":"poll","url":url,"tab":9])["id"] as? String == recoverable.id.uuidString)
        _ = restored.browserCommand(["kind":"result","url":url,"tab":9,"id":recoverable.id.uuidString,"state":"uncertain"])
        restored.selected = recoverable.id
        restored.resolveCurrent(sent:false)
        restored.resumeDelivery()
        check(restored.autoSend && restored.stageOf(recoverable) == .queued)
        restored.cancelDelivery(recoverable)
        check(restored.stageOf(recoverable) == .held && restored.imageURL(recoverable) != nil)
        check(restored.browserCommand(["kind":"poll","url":url,"tab":9])["id"] == nil)
        // Explicit iPad consent authorizes one batch without enabling continuous intake.
        restored.pauseDelivery()
        var share = WireHeader(kind:"photo",byteCount:bytes.count,sha256:model.records[0].sha256)
        share.deliveryIntent = "explicitShare"; share.sendToAI = true; share.sessionID = restored.catalog.activeLessonID
        try restored.receive(bytes,header:share)
        let shared = restored.records.first { $0.id == share.id }!
        check(restored.stageOf(shared) == .queued && !restored.autoSend)
        restored.cancelDelivery(shared)
        try restored.receive(bytes,header:share) // Lost receipt retry cannot undo cancellation.
        check(restored.stageOf(shared) == .held)
        var wrong = WireHeader(kind:"photo",byteCount:bytes.count,sha256:share.sha256)
        wrong.deliveryIntent = "explicitShare"; wrong.sendToAI = true; wrong.sessionID = UUID()
        try restored.receive(bytes,header:wrong)
        check(restored.stageOf(restored.records.first { $0.id == wrong.id }!) == .held)
        var valid = WireHeader(kind:"photo",byteCount:bytes.count,sha256:share.sha256)
        valid.deliveryIntent = "explicitShare"; valid.sendToAI = true; valid.sessionID = restored.catalog.activeLessonID
        try restored.receive(bytes,header:valid)
        check(restored.browserCommand(["kind":"poll","url":url,"tab":9])["id"] as? String == valid.id.uuidString)
        // Deleting a different saved photo is allowed while an upload is active.
        restored.selectedPhotoIDs = [shared.id]
        check(restored.batchDeleteSelected())
        check(restored.records.first { $0.id == shared.id } == nil)
        restored.selectedPhotoIDs = [valid.id]
        check(!restored.batchDeleteSelected())
        check(restored.records.contains { $0.id == valid.id })
        _ = restored.browserCommand(["kind":"defer","url":url,"tab":9,"id":valid.id.uuidString,"detail":"等待：草稿"])
        restored.pauseDelivery()
        check(restored.browserCommand(["kind":"status","url":url,"tab":9])["pendingQueued"] as? Int == 1)
        check(restored.browserCommand(["kind":"resume","url":url,"tab":9])["ok"] as? Bool == true)
        check(restored.stageOf(restored.records.first { $0.id == wrong.id }!) == .held)
        print("PASS: no-course USB receipt → Inbox → Section assignment → browser lease/result → duplicate retry → persisted binding")
    }
}
