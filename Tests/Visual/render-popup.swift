import AppKit
import WebKit

@MainActor final class PageReady: NSObject, WKNavigationDelegate {
    var ready = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { ready = true }
}
@main struct RenderPopup {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let rect = NSRect(x: 0, y: 0, width: 380, height: 700)
        let web = WKWebView(frame: rect, configuration: configuration), delegate = PageReady()
        let window = NSWindow(contentRect: rect, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = web; web.navigationDelegate = delegate
        let root = URL(fileURLWithPath: "build/popup-preview", isDirectory: true)
        web.loadFileURL(root.appendingPathComponent("index.html"), allowingReadAccessTo: root)
        let deadline = Date().addingTimeInterval(15)
        while !delegate.ready && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        guard delegate.ready else { throw CocoaError(.fileReadUnknown) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        var finished = false, failure: Error?
        let options = WKSnapshotConfiguration(); options.rect = rect
        web.takeSnapshot(with: options) { image, error in
            defer { finished = true }; failure = error
            guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { return }
            do { try png.write(to: URL(fileURLWithPath: "build/aurora-states/chrome-popup.png")) } catch { failure = error }
        }
        while !finished && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        if let failure { throw failure }; guard finished else { throw CocoaError(.fileWriteUnknown) }
        print("Rendered isolated Chrome popup HTML/CSS (mocked bridge, no browser permissions)")
    }
}
