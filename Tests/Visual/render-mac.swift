import SwiftUI
import AppKit
import SnapSendCore

@main struct RenderWorkspace {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let model = WorkspaceModel(preview: true)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try PhotoStore(directory: folder)
        let first = try store.createCourse(name: "STA256")
        try store.renameLesson(first.id, title: "概率密度与期望")
        _ = try store.startLesson(courseID: first.courseID, title: "离散随机变量")
        _ = try store.createCourse(name: "PHY245")
        try store.activateLesson(nil)
        model.catalog = store.catalog; model.selectedLesson = first.id
        for (name, scheme) in [("mac-light", ColorScheme.light), ("mac-dark", ColorScheme.dark)] {
            let host = NSHostingView(rootView: WorkspaceView(model: model).environment(\.colorScheme, scheme))
            let rect = NSRect(x: 0, y: 0, width: 1280, height: 820)
            let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = host
            host.frame = rect
            host.layoutSubtreeIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: rect) else { throw CocoaError(.fileWriteUnknown) }
            host.cacheDisplay(in: rect, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: URL(fileURLWithPath: "build/" + name + ".png"))
            print("Rendered " + name)
        }
    }
}
