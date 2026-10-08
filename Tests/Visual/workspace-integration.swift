import SwiftUI
import AppKit
import SnapSendCore

@main struct WorkspaceIntegration {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PhotoStore(directory: root)
        let model = WorkspaceModel(preview: true)
        try model.configurePreview(store: store, sending: false)
        let bytes = try Data(contentsOf: URL(fileURLWithPath: "assets/brand/SnapMark.png"))
        try model.receive(bytes)
        precondition(model.usbConnected && model.inboxPhotos.count == 1 && model.catalog.activeLessonID == nil)
        let firstPhoto = model.records[0].id
        model.autoSendPromptOnStartLesson = false
        model.createCourse("STA256")
        let section = model.targetSection!.id
        model.autoSendPromptOnStartLesson = false
        let url = "https://chatgpt.com/g/g-p-sta256/c/integration-chat"
        precondition(model.browserCommand(["kind": "bind", "url": url, "tab": 7])["ok"] as? Bool == true)
        precondition(store.catalog.sections?.first?.chatURL == url && !model.autoSend)
        model.assignPhotos([firstPhoto], to: section, send: true)
        precondition(model.deliveries.first?.state == .queued && model.autoSend)
        let poll = model.browserCommand(["kind": "poll", "url": url, "tab": 7])
        precondition(poll["id"] as? String == firstPhoto.uuidString && poll["jpeg"] != nil)
        let active = model.catalog.activeLessonID
        model.chooseSection(nil); model.createCourse("Do not switch while sending")
        precondition(model.catalog.activeLessonID == active && model.catalog.courses.filter { $0.name == "Do not switch while sending" }.isEmpty)
        precondition(model.browserCommand(["kind": "submitting", "url": url, "tab": 7, "id": firstPhoto.uuidString])["ok"] as? Bool == true)
        precondition(model.browserCommand(["kind": "result", "url": url, "tab": 7, "id": firstPhoto.uuidString, "state": "sent"])["ok"] as? Bool == true)
        precondition(model.deliveries.first?.state == .sent)
        let todayArchive = model.boundLesson
        model.resolveTarget(now: Calendar.current.date(byAdding: .day, value: 1, to: Date())!)
        precondition(model.boundLesson != todayArchive && model.autoSend && model.boundChat == url)
        precondition(model.browserCommand(["kind": "status", "url": url, "tab": 7])["matching"] as? Bool == true)
        // Retry of the same USB ID must not duplicate a delivery or relocate its archive.
        let header = WireHeader(kind: "photo", id: firstPhoto, byteCount: bytes.count, sha256: model.records[0].sha256)
        try model.receive(bytes, header: header)
        precondition(model.records.count == 1 && model.deliveries.count == 1 && model.deliveries.first?.state == .sent)
        let restored = WorkspaceModel(preview: true)
        try restored.configurePreview(store: PhotoStore(directory: root), sending: false)
        precondition(restored.chatMatchesClass && restored.boundChat == url)
        precondition(restored.stageOf(restored.records[0]) == .sent)
        precondition(restored.browserCommand(["kind":"restore","section":section.uuidString,"url":"https://chatgpt.com/c/wrong","tab":9])["ok"] as? Bool == false)
        precondition(restored.browserCommand(["kind":"restore","section":section.uuidString,"url":url,"tab":9])["ok"] as? Bool == true)
        precondition(restored.browserCommand(["kind":"status","url":url,"tab":9])["matching"] as? Bool == true)
        print("PASS: no-course USB receipt → Inbox → Section assignment → browser lease/result → duplicate retry → persisted binding")
    }
}
