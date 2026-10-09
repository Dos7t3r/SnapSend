import SwiftUI
import AppKit

struct MacThumbnail: View {
    let url: URL
    var pixels: Int = Aurora.Space.thumbnailPixels
    var fit = false
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image {
                if fit { Image(nsImage: image).resizable().scaledToFit() }
                else { Image(nsImage: image).resizable().scaledToFill() }
            } else { Rectangle().fill(Aurora.Colors.white.opacity(Aurora.Alpha.faint)).overlay { Image(systemName: "photo").foregroundStyle(Aurora.Colors.secondary) } }
        }.task(id: url) {
            let cg = await ThumbnailLoader.shared.load(url, pixels: pixels)
            guard !Task.isCancelled else { return }
            image = cg.map { NSImage(cgImage: $0, size: .zero) }
        }.onDisappear { image = nil }
    }
}
