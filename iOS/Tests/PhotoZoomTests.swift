import XCTest
import UIKit
import SwiftUI
@testable import SnapSendPhone

final class PhotoZoomTests: XCTestCase {
    @MainActor private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600)).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        }
        try XCTUnwrap(image.jpegData(compressionQuality: 0.9)).write(to: url)
        return url
    }
    @MainActor func testImageGetsFrameAfterInitiallyZeroBoundsAndResetsOnResize() throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let view = PhotoScrollView(frame: .zero)
        view.setPhoto(url)
        XCTAssertNotNil(view.photo.image)
        view.frame = CGRect(x: 0, y: 0, width: 390, height: 600)
        view.layoutIfNeeded()
        XCTAssertEqual(view.photo.frame.size, view.bounds.size)
        view.setZoomScale(2, animated: false)
        view.frame.size = CGSize(width: 600, height: 390)
        view.setNeedsLayout(); view.layoutIfNeeded()
        XCTAssertEqual(view.zoomScale, 1)
        XCTAssertEqual(view.photo.frame.size, view.bounds.size)
    }
    @MainActor func testMissingPhotoShowsVisibleRecoveryMessage() {
        let view = PhotoScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        view.setPhoto(URL(fileURLWithPath: "/missing/snapsend-test-photo.jpg")); view.layoutIfNeeded()
        XCTAssertNil(view.photo.image)
        XCTAssertFalse(view.loadMessage.isHidden)
        XCTAssertTrue(view.loadMessage.text?.contains("图片无法读取") == true)
        XCTAssertGreaterThan(view.loadMessage.frame.height, 0)
    }
    @MainActor func testSwiftUIPagedViewerDisplaysImageRatherThanBlackViewport() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let record = PhonePhoto(id: UUID(), url: url, createdAt: Date(), receivedByMac: true, context: nil)
        let root = PhotoPager(photos: [record], selectedID: .constant(record.id))
        let host = UIHostingController(rootView: root)
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene { window = UIWindow(windowScene: scene) }
        else { window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844)) }
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(300))
        host.view.layoutIfNeeded()
        func images(_ view: UIView) -> [UIImageView] {
            (view as? UIImageView).map { [$0] } ?? view.subviews.flatMap(images)
        }
        let rendered = try XCTUnwrap(images(host.view).first(where: { $0.image != nil }))
        XCTAssertGreaterThan(rendered.frame.width, 100)
        XCTAssertGreaterThan(rendered.frame.height, 100)
        let scroll = try XCTUnwrap(rendered.superview as? PhotoScrollView)
        scroll.setZoomScale(2, animated: false)
        host.rootView = root
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(images(host.view).first(where: { $0.image != nil }) === rendered, "An ordinary SwiftUI update must not recreate the active image page")
        XCTAssertEqual(scroll.zoomScale, 2)
        scroll.setZoomScale(1, animated: false)
        let snapshot = UIGraphicsImageRenderer(bounds: rendered.bounds).image { _ in rendered.drawHierarchy(in: rendered.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: snapshot); attachment.name = "Rendered classroom photo"; attachment.lifetime = .keepAlways; add(attachment)
        let cg = try XCTUnwrap(snapshot.cgImage)
        let space = CGColorSpaceCreateDeviceRGB()
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertGreaterThan(pixel[0], 30, "Synthetic red image should render visibly, not black")
    }
    @MainActor func testRedesignedPhoneWorkspaceRendersInLightAndDark() async throws {
        for (name, scheme) in [("Phone classroom light", ColorScheme.light), ("Phone classroom dark", ColorScheme.dark)] {
            let model = SnapSendPhone.PhoneModel(preview: true)
            let root = SnapSendPhone.PhoneView(model: model).environment(\.colorScheme, scheme)
            let host = UIHostingController(rootView: root)
            let window: UIWindow
            if let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene { window = UIWindow(windowScene: scene) }
            else { window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844)) }
            window.rootViewController = host; window.makeKeyAndVisible()
            window.frame = CGRect(x: 0, y: 0, width: 430, height: 932)
            host.view.frame = window.bounds
            try await Task.sleep(for: .milliseconds(400))
            host.view.layoutIfNeeded()
            XCTAssertGreaterThan(host.view.bounds.width, 300)
            XCTAssertGreaterThan(host.view.bounds.height, 700)
            let snapshot = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
            XCTAssertNotNil(snapshot.cgImage)
            let attachment = XCTAttachment(image: snapshot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            window.isHidden = true
        }
    }

}
