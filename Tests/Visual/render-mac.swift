import SwiftUI
import AppKit
import SnapSendCore

@main struct RenderWorkspace {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "build/aurora-states")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for state in ["ready", "phone-off", "extension-off", "no-section", "sending", "failed", "empty", "inbox", "courses", "settings"] {
            let model = WorkspaceModel(preview: true)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = try PhotoStore(directory: folder)
            let first = try store.createCourse(name: "STA256")
            var section = store.catalog.section(for: first.id)!
            section.name = "LEC0101"; section.chatURL = "https://chatgpt.com/g/g-p-sta256/c/test-conversation"
            try store.updateSection(section)
            try store.updateSection(CourseSection(courseID: first.courseID, name: "TUT0112"))
            if state == "no-section" || state == "inbox" { try store.selectSection(nil); _ = try store.routeLesson() }
            let photoURL = URL(fileURLWithPath: "assets/brand/SnapMark.png")
            let data = try Data(contentsOf: photoURL)
            if state != "empty" { _ = try store.save(data, sessionID: state == "inbox" || state == "no-section" ? store.catalog.inboxLessonID : first.id) }
            try model.configurePreview(store: store, usb: state != "phone-off", connected: state != "extension-off", sending: state != "no-section" && state != "inbox" && state != "failed")
            if let photo = model.records.first, state != "inbox", state != "no-section" {
                model.deliveries = [DeliveryEntry(id: photo.id, lessonID: first.id, destination: "chrome", state: state == "sending" ? .preparing : state == "failed" ? .uncertain : .sent, detail: "fixture")]
            }
            if state == "failed" { model.browserPageStatus = "发送结果未确认，请打开聊天核对" }
            let host = NSHostingView(rootView: WorkspaceView(model: model, page: state == "inbox" ? .inbox : state == "courses" ? .courses : state == "settings" ? .settings : .overview).environment(\.colorScheme, .dark))
            let rect = NSRect(x: 0, y: 0, width: 1080, height: 720)
            let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua); window.contentView = host; host.frame = rect
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: rect) else { throw CocoaError(.fileWriteUnknown) }
            host.cacheDisplay(in: rect, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: root.appendingPathComponent(state + ".png")); print("Rendered " + state)
        }
    }
}
