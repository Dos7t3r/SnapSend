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
            let snapshot = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            XCTAssertNotNil(snapshot.cgImage)
            let attachment = XCTAttachment(image: snapshot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            window.isHidden = true
        }
    }

    @MainActor func testOfflineCameraSavePersistsWithoutClassAndSurvivesReload() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = PhoneModel(preview: true)
        try await model.configureTesting(directory: folder)
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let image = try XCTUnwrap(UIImage(contentsOfFile: url.path))
        model.save(image, context: nil, quality: 0.9)
        for _ in 0..<30 where model.savingCount > 0 { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(model.photos.count, 1)
        XCTAssertNil(model.photos.first?.context)
        XCTAssertFalse(model.photos.first?.receivedByMac ?? true)
        let restored = try PhoneLibrary(directory: folder)
        XCTAssertEqual(restored.photos.first?.id, model.lastSavedID)
        XCTAssertNotNil(UIImage(contentsOfFile: restored.photos[0].url.path))
    }
    @MainActor func testPhoneStateMatrix() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let course = UUID(), lesson = SnapSendPhone.Lesson(id: UUID(), courseID: course, title: "课堂", startedAt: Date(), timeZoneID: TimeZone.current.identifier)
        let context = SnapSendPhone.LessonContext(lesson: lesson, courseName: "STA256", sectionName: "LEC0101")
        for state in ["capture-connected", "capture-offline", "capture-no-target", "album", "album-empty", "viewer", "settings", "pairing", "light", "small", "large-text"] {
            let model = PhoneModel(preview: true)
            model.connected = state == "capture-connected"; model.peerName = "MacBook Pro"
            if state != "capture-no-target" { model.activeContext = context }
            if state != "album-empty" {
                model.photos = [SnapSendPhone.PhonePhoto(id: UUID(), url: url, createdAt: Date(), receivedByMac: false, context: context), SnapSendPhone.PhonePhoto(id: UUID(), url: url, createdAt: Date(), receivedByMac: true, context: context, stage: "failed", stageDetail: "上传失败")]
            }
            if state == "pairing" { model.pairingCode = "482193"; model.pairingExpiresAt = Date().addingTimeInterval(60) }
            let page = state == "settings" || state == "large-text" ? "settings" : ["album", "album-empty", "light", "small"].contains(state) ? "history" : "capture"
            let root: AnyView
            if state == "viewer", let photo = model.photos.first { root = AnyView(LessonPhotoViewer(model: model, photos: model.photos, initialID: photo.id)) }
            else { root = AnyView(PhoneView(model: model, initialPage: page).environment(\.colorScheme, state == "light" ? .light : .dark).environment(\.dynamicTypeSize, state == "large-text" ? .accessibility2 : .large)) }
            let host = UIHostingController(rootView: root)
            let window = UIApplication.shared.connectedScenes.first.flatMap { $0 as? UIWindowScene }.map { UIWindow(windowScene: $0) } ?? UIWindow()
            window.frame = CGRect(x: 0, y: 0, width: state == "small" ? 320 : 430, height: state == "small" ? 568 : 932)
            window.rootViewController = host; window.makeKeyAndVisible()
            window.frame = CGRect(x: 0, y: 0, width: state == "small" ? 320 : 430, height: state == "small" ? 568 : 932)
            host.view.frame = window.bounds
            try await Task.sleep(for: .milliseconds(700)); host.view.layoutIfNeeded()
            XCTAssertGreaterThan(host.view.bounds.height, 500)
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = "Phone Aurora " + state; attachment.lifetime = .keepAlways; add(attachment)
            window.isHidden = true
        }
    }

    @MainActor func testPrivateCaptureChoicePersistsAndIsNotChangedByUSBReceipt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = PhoneModel(preview: true)
        try await model.configureTesting(directory: folder)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { ctx in UIColor.blue.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100)) }
        model.save(image, context: nil, sendToAI: false)
        for _ in 0..<100 where model.photos.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.photos.count, 1)
        XCTAssertFalse(try XCTUnwrap(model.photos.first).sendToAI)
        let storage = try PhoneStorage(directory: folder)
        let photos = try await storage.acknowledge(try XCTUnwrap(model.photos.first).id)
        XCTAssertFalse(photos[0].sendToAI)
        let restored = PhoneModel(preview: true); try await restored.configureTesting(directory: folder)
        XCTAssertFalse(restored.photos[0].sendToAI)
    }

    @MainActor func testCaptureFiveStatesAtDeviceSize() async throws {
        let url = try fixture(); defer { try? FileManager.default.removeItem(at: url) }
        let lesson = SnapSendPhone.Lesson(id: UUID(), courseID: UUID(), title: "课堂", startedAt: Date(), timeZoneID: TimeZone.current.identifier)
        let context = SnapSendPhone.LessonContext(lesson: lesson, courseName: "MAT232", sectionName: "LEC0101")
        let small = min(UIScreen.main.bounds.width, UIScreen.main.bounds.height) < 400
        for size in [small ? CGSize(width: 375, height: 667) : CGSize(width: 440, height: 956)] {
            for state in ["connected", "offline", "no-target", "denied", "preparing"] {
                let model = PhoneModel(preview: true)
                model.connected = state != "offline"
                model.peerName = "MacBook Air · 一个非常非常长的电脑名字"
                model.activeContext = state == "no-target" ? nil : context
                model.photos = [SnapSendPhone.PhonePhoto(id: UUID(), url: url, createdAt: Date(), receivedByMac: true, context: context, stage: "sent")]
                let camera = CameraCapture(); camera.configurePreview(presets: [0.5, 1, 2, 3])
                let cameraState: CameraCapture.State = state == "denied" ? .denied : state == "preparing" ? .preparing : .unavailable
                var frames: [String: CGRect] = [:]
                let root = PhoneView(model: model, cameraOverride: cameraState, camera: camera, layoutObserver: { frames = $0 })
                let host = PortraitCaptureHost(rootView: root)
                let window = UIApplication.shared.connectedScenes.first.flatMap { $0 as? UIWindowScene }.map { UIWindow(windowScene: $0) } ?? UIWindow()
                window.rootViewController = host; window.makeKeyAndVisible()
                host.setNeedsUpdateOfSupportedInterfaceOrientations()
                window.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { error in print("Portrait scene update: \(error)") }
                try await Task.sleep(for: .milliseconds(600))
                host.view.frame = window.bounds
                print("Device window: \(window.bounds), safe=\(window.safeAreaInsets), orientation=\(window.windowScene?.interfaceOrientation.rawValue ?? -1)")
                defer { window.isHidden = true; window.rootViewController = nil }
                try await Task.sleep(for: .milliseconds(900)); host.view.layoutIfNeeded()
                let debugImage = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
                try debugImage.pngData()?.write(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Capture-\(Int(size.width))-\(state).png"))
                let shutter = try XCTUnwrap(frames["shutter"], "shutter")
                let dock = try XCTUnwrap(frames["dock"])
                let preview = try XCTUnwrap(frames["preview"])
                let controls = try XCTUnwrap(frames["controls"])
                let thumbnail = try XCTUnwrap(frames["thumbnail"])
                let top = try XCTUnwrap(frames["top"])
                XCTAssertEqual(host.view.bounds.width, size.width, accuracy: 0.1)
                XCTAssertEqual(shutter.midX, host.view.bounds.midX, accuracy: 0.01, "Shutter must be at screen center")
                XCTAssertEqual(shutter.width, 76, accuracy: 0.1)
                XCTAssertEqual(dock.height, 88, accuracy: 0.1)
                XCTAssertEqual(preview.height / preview.width, 4.0 / 3.0, accuracy: 0.001, "Portrait full sensor ratio")
                XCTAssertLessThanOrEqual(top.maxY + 12, preview.minY + 0.1)
                XCTAssertLessThanOrEqual(preview.maxY + 12, controls.minY + 0.1)
                XCTAssertLessThanOrEqual(controls.maxY, dock.minY)
                XCTAssertEqual(thumbnail.width, 56, accuracy: 0.1)
                for key in ["connection", "flash-button", "quality-button", "album-button", "settings-button", "zoom-0.5", "zoom-1.0", "zoom-2.0", "zoom-3.0"] {
                    let frame = try XCTUnwrap(frames[key], key)
                    XCTAssertGreaterThanOrEqual(frame.width, 44 - 0.1, key)
                    XCTAssertGreaterThanOrEqual(frame.height, 44 - 0.1, key)
                    XCTAssertGreaterThanOrEqual(frame.minX, 0, key)
                    XCTAssertLessThanOrEqual(frame.maxX, size.width, key)
                }
                let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                let attachment = XCTAttachment(image: image); attachment.name = "Capture polish \(Int(size.width))x\(Int(size.height)) \(state)"; attachment.lifetime = .keepAlways; add(attachment)
                print("Capture metrics \(size) \(state): center error=\(shutter.midX - host.view.bounds.midX), preview=\(preview), controls=\(controls), dock=\(dock)")
                window.isHidden = true
            }
        }
    }
    func testChineseDateDoesNotFollowEnglishSystemLocale() {
        let date = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(SnapTheme.date(date).contains("月"))
        XCTAssertTrue(SnapTheme.date(date).contains("日"))
        XCTAssertFalse(SnapTheme.date(date).contains("AM"))
        XCTAssertFalse(SnapTheme.date(date).contains("PM"))
    }

}

private final class PortraitCaptureHost<Content: View>: UIHostingController<Content> {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .portrait }
}
