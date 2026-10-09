import SwiftUI
import AppKit
import SnapSendCore

@main struct RenderWorkspace {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let interactive = CommandLine.arguments.contains("--interactive")
        if interactive { NSApplication.shared.setActivationPolicy(.regular) }
        let root = interactive ? FileManager.default.temporaryDirectory.appendingPathComponent("SnapSendInteractionQA") : URL(fileURLWithPath: "build/aurora-states")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let states = ["ready", "phone-off", "extension-off", "no-section", "sending", "failed", "empty", "inbox", "courses", "settings", "long-overview", "long-history", "long-inbox", "long-courses", "reduced-motion", "ai-waiting"]
        for state in interactive ? ["long-overview"] : states {
            let model = WorkspaceModel(preview: true)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = try PhotoStore(directory: folder)
            let first = try store.createCourse(name: "STA256")
            var section = store.catalog.section(for: first.id)!
            section.name = "LEC0101"; section.chatURL = "https://chatgpt.com/g/g-p-sta256/c/test-conversation"
            try store.updateSection(section)
            try store.updateSection(CourseSection(courseID: first.courseID, name: "TUT0112"))
            if state == "no-section" || state == "inbox" || state == "long-inbox" { try store.selectSection(nil); _ = try store.routeLesson() }
            let photoURL = interactive ? Bundle.main.url(forResource: "SnapMark", withExtension: "png")! : URL(fileURLWithPath: "assets/brand/SnapMark.png")
            let data = try Data(contentsOf: photoURL)
            if state != "empty" { _ = try store.save(data, sessionID: state == "inbox" || state == "no-section" ? store.catalog.inboxLessonID : first.id) }
            if state.hasPrefix("long-") {
                for _ in 0..<30 { _ = try store.save(data, sessionID: state == "long-inbox" ? store.catalog.inboxLessonID : first.id) }
                if state == "long-courses" { for index in 1...8 { _ = try store.createCourse(name: "课程 \(index)") } }
                for index in 1...8 { try store.updateSection(CourseSection(courseID: first.courseID, name: index == 1 ? "默认 Section" : "Section \(index)")) }
            }
            try model.configurePreview(store: store, usb: state != "phone-off", connected: state != "extension-off", sending: state != "no-section" && state != "inbox" && state != "failed")
            if let photo = model.records.first, state != "inbox", state != "no-section" {
                model.deliveries = [DeliveryEntry(id: photo.id, lessonID: first.id, destination: "chrome", state: state == "sending" ? .preparing : state == "failed" ? .uncertain : .sent, detail: "fixture")]
            }
            if state == "ai-waiting" { model.browserPageStatus = "等待：AI 正在回答" }
            if state == "failed" { model.browserPageStatus = "发送结果未确认，请打开聊天核对" }
            let host = NSHostingView(rootView: WorkspaceView(model: model, page: state == "long-history" ? .tasks : state == "inbox" || state == "long-inbox" ? .inbox : state == "courses" || state == "long-courses" ? .courses : state == "settings" ? .settings : .overview, history: false).environment(\.colorScheme, .dark).environment(\.auroraReduceMotion, state == "reduced-motion"))
            let rect = NSRect(x: 0, y: 0, width: state.hasPrefix("long-") ? 960 : 1080, height: state.hasPrefix("long-") ? 640 : 720)
            let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua); window.contentView = host; host.frame = rect
            if interactive {
                window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
                window.title = "SnapSend 交互测试（隔离数据）"
                window.contentMinSize = NSSize(width: 960, height: 640)
                window.makeKeyAndOrderFront(nil)
                NSApplication.shared.activate()
                let heartbeat = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
                    MainActor.assumeIsolated { _ = model.browserCommand(["kind":"status", "tab":7, "url":section.chatURL!]) }
                }
                NSApplication.shared.run()
                heartbeat.invalidate()
            }
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(1.2))
            let scrolls = descendants(host).compactMap { $0 as? NSScrollView }
            if state.hasPrefix("long-") {
                guard let scroll = scrolls.max(by: { $0.convert($0.bounds, to: host).maxX < $1.convert($1.bounds, to: host).maxX }) else { fatalError("No page scroll view: " + state) }
                let height = scroll.documentView?.frame.height ?? 0
                if state != "long-courses" { precondition(height > scroll.contentView.bounds.height, "Long list must overflow: " + state) }
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, height - scroll.contentView.bounds.height)))
                scroll.reflectScrolledClipView(scroll.contentView)
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                print("Scroll \(state): document=\(height), viewport=\(scroll.contentView.bounds.height), offset=\(scroll.contentView.bounds.origin.y)")
            }
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: rect) else { throw CocoaError(.fileWriteUnknown) }
            host.cacheDisplay(in: rect, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: root.appendingPathComponent(state + ".png")); print("Rendered " + state)
        }
    }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
}
