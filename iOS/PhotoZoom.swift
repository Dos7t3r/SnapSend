import SwiftUI
import UIKit
import ImageIO

struct ZoomPhoto: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> PhotoScrollView { PhotoScrollView() }
    func updateUIView(_ view: PhotoScrollView, context: Context) {
        if view.loadedURL != url { view.setPhoto(url) }
        view.setNeedsLayout()
    }
}
final class PhotoScrollView: UIScrollView, UIScrollViewDelegate {
    let photo = UIImageView()
    let loadMessage = UILabel()
    private(set) var loadedURL: URL?
    var zoomChanged: ((Bool) -> Void)?
    private var lastViewport = CGSize.zero
    func setPhoto(_ url: URL) {
        loadedURL = url
        setZoomScale(1, animated: false)
        contentOffset = .zero
        // Bound decoded memory while retaining enough detail for classroom zooming.
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(source, 0,
                [kCGImageSourceCreateThumbnailFromImageAlways: true,
                 kCGImageSourceCreateThumbnailWithTransform: true,
                 kCGImageSourceThumbnailMaxPixelSize: 2560] as CFDictionary) {
            photo.image = UIImage(cgImage: image)
            loadMessage.isHidden = true
        } else {
            photo.image = nil
            loadMessage.text = "图片无法读取\n请返回相册后重试；原图不会被删除。"
            loadMessage.isHidden = false
        }
        setNeedsLayout()
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        minimumZoomScale = 1; maximumZoomScale = 5
        delegate = self; backgroundColor = .black
        contentInsetAdjustmentBehavior = .never
        showsVerticalScrollIndicator = false; showsHorizontalScrollIndicator = false
        photo.contentMode = .scaleAspectFit
        photo.accessibilityLabel = "课堂照片"
        addSubview(photo)
        loadMessage.textColor = .white; loadMessage.textAlignment = .center
        loadMessage.numberOfLines = 0; loadMessage.isHidden = true
        addSubview(loadMessage)
        panGestureRecognizer.isEnabled = false
        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        tap.numberOfTapsRequired = 2; addGestureRecognizer(tap)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0 else { return }
        if lastViewport != bounds.size {
            lastViewport = bounds.size
            if zoomScale != 1 { setZoomScale(1, animated: false) }
        }
        if abs(zoomScale - 1) < 0.001 {
            photo.transform = .identity
            photo.frame = CGRect(origin: .zero, size: bounds.size)
            contentSize = bounds.size
        }
        loadMessage.frame = CGRect(origin: contentOffset, size: bounds.size)
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { photo }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        let zoomed = zoomScale > 1.01
        panGestureRecognizer.isEnabled = zoomed
        zoomChanged?(zoomed)
    }
    @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
        if zoomScale > 1.01 { setZoomScale(1, animated: true) }
        else {
            let point = gesture.location(in: photo)
            let size = CGSize(width: bounds.width / 2.5, height: bounds.height / 2.5)
            zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }
}
