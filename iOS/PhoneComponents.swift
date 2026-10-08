import SwiftUI
import UIKit

extension PhonePhoto {
    var deliveryFailed: Bool { stage == "failed" || stage == "uncertain" }
    var macSaved: Bool { receivedByMac || ["received", "held", "queued", "preparing", "submitting", "sent", "uncertain", "failed"].contains(stage ?? "") }
    func statusText(sendingID: UUID?) -> String {
        if sendingID == id { return "已保存在手机 · 正在传到 Mac" }
        switch stage {
        case "held": return "仅保存 · 不会自动发送给 AI"
        case "sent": return "AI 已接收"
        case "uncertain": return "AI 结果待核对 · 请在 Mac 处理"
        case "failed": return "AI 发送失败 · 请在 Mac 重试"
        case "preparing", "submitting": return "已到 Mac · 正在发送给 AI"
        case "queued": return "已到 Mac · 等待 AI 投递"
        default: if !sendToAI { return macSaved ? "仅保存 · 已到 Mac" : "仅保存 · 等待 USB 归档" }; return macSaved ? "已到 Mac · 等待 AI 投递" : "已保存在手机 · 等待 USB 传输"
        }
    }
    func statusColor(sendingID: UUID?) -> Color { deliveryFailed ? SnapTheme.failure : stage == "sent" ? SnapTheme.success : macSaved ? SnapTheme.blue : SnapTheme.local }
    func statusIcon(sendingID: UUID?) -> String { deliveryFailed ? "exclamationmark.circle.fill" : stage == "sent" ? "checkmark.seal.fill" : sendingID == id ? "arrow.up.circle" : macSaved ? "desktopcomputer" : "clock" }
}
struct PhotoThumbnail: View {
    let url: URL
    @State private var image: UIImage?
    var body: some View {
        Group { if let image { Image(uiImage: image).resizable().scaledToFill() } else { Rectangle().fill(SnapTheme.waiting.opacity(SnapTheme.Alpha.icon)).overlay { Image(systemName: "photo") } } }
            .task(id: url) { let cg = await ThumbnailLoader.shared.load(url, pixels: SnapTheme.Layout.thumbPixels); guard !Task.isCancelled else { return }; image = cg.map { UIImage(cgImage: $0) } }
            .onDisappear { image = nil }
    }
}
struct PhotoGallerySelection: Identifiable {
    let id: UUID
    let photos: [PhonePhoto]
    init(photo: PhonePhoto, photos: [PhonePhoto]) { id = photo.id; self.photos = (photos.contains(where: { $0.id == photo.id }) ? photos : photos + [photo]).sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt } }
}
struct DeliveryRing: View {
    var photo: PhonePhoto?
    var thumbnail = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var completed = false
    @State private var completionTask: Task<Void, Never>?
    @State private var shake = false
    private var sent: Bool { photo?.stage == "sent" }
    var body: some View {
        ZStack {
            ForEach(0..<3) { i in
                let end = Double(i + 1) / 3 - SnapTheme.Layout.ringGap
                RoundedRectangle(cornerRadius: thumbnail ? 20 : SnapTheme.Layout.ring / 2).trim(from: Double(i) / 3 + (sent ? 0 : SnapTheme.Layout.ringGap), to: sent ? Double(i + 1) / 3 : end)
                    .stroke(color(i), style: StrokeStyle(lineWidth: SnapTheme.Layout.ringLine, lineCap: .round))
            }
        }.frame(width: thumbnail ? 67 : SnapTheme.Layout.ring, height: thumbnail ? 67 : SnapTheme.Layout.ring)
            .scaleEffect(completed && !reduceMotion ? SnapTheme.Motion.arrival : 1)
            .animation(reduceMotion ? .easeOut : SnapTheme.Motion.state, value: photo?.stage).animation(reduceMotion ? SnapTheme.Motion.fade : SnapTheme.Motion.state, value: photo?.macSaved).animation(reduceMotion ? SnapTheme.Motion.fade : SnapTheme.Motion.state, value: photo?.id)
            .onChange(of: sent) { _, value in
                completionTask?.cancel(); completed = false
                guard value, !reduceMotion else { return }
                completionTask = Task {
                    withAnimation(SnapTheme.Motion.state) { completed = true }
                    do { try await Task.sleep(for: .seconds(SnapTheme.Motion.flight)) } catch { return }
                    withAnimation(SnapTheme.Motion.state) { completed = false }
                }
            }
            .onChange(of: photo?.id) { _, _ in completionTask?.cancel(); completed = false; shake = false }
            .onDisappear { completionTask?.cancel() }
            .offset(x: shake ? SnapTheme.Layout.tiny : 0)
            .task(id: photo?.stage) {
                guard photo?.deliveryFailed == true, !reduceMotion else { return }
                withAnimation(SnapTheme.Motion.press) { shake = true }; try? await Task.sleep(for: .seconds(SnapTheme.Motion.flight / 2)); withAnimation(SnapTheme.Motion.state) { shake = false }
            }
            .accessibilityLabel(photo?.statusText(sendingID: nil) ?? "尚无照片")
    }
    private func color(_ index: Int) -> Color {
        if sent { return SnapTheme.success }
        if photo?.deliveryFailed == true, index == (photo?.macSaved == true ? 2 : 1) { return SnapTheme.failure }
        if index == 0, photo != nil { return SnapTheme.local }
        if index == 1, photo?.macSaved == true { return SnapTheme.blue }
        return SnapTheme.waiting.opacity(SnapTheme.Alpha.dim)
    }
}
struct PhoneConnectionPill: View {
    @ObservedObject var model: PhoneModel
    var compact = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(model.connected ? "已连接 · \(model.peerName.isEmpty ? "Mac" : model.peerName)" : "等待连接", systemImage: model.connected ? "circle.fill" : "circle")
                .font(SnapTheme.TypeStyle.micro).lineLimit(1).foregroundStyle(model.connected ? SnapTheme.success : SnapTheme.waiting)
                .padding(.horizontal, 8).frame(height: compact ? 36 : 44).frame(maxWidth: .infinity, alignment: .leading).modifier(SnapGlass())
        }.buttonStyle(SnapTouchStyle()).animation(SnapTheme.Motion.state, value: model.connected)
    }
}
struct PhoneChain: View {
    @ObservedObject var model: PhoneModel
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: SnapTheme.Layout.card) {
                accessibleNode("iphone", "手机", "原图本地保存", SnapTheme.local)
                accessibleNode("laptopcomputer", "Mac", model.connected ? "已连接" : "等待 USB", model.connected ? SnapTheme.blue : SnapTheme.waiting)
                accessibleNode("sparkles", "AI", "投递由 Mac 管理", SnapTheme.success)
            }
        } else {
        HStack(spacing: SnapTheme.Layout.gap) {
            node("iphone", "手机", "原图本地保存", SnapTheme.local)
            Image(systemName: "chevron.right").foregroundStyle(SnapTheme.waiting)
            node("laptopcomputer", "Mac", model.connected ? "已连接" : "等待 USB", model.connected ? SnapTheme.blue : SnapTheme.waiting)
            Image(systemName: "chevron.right").foregroundStyle(SnapTheme.waiting)
            node("sparkles", "AI", model.photos.last?.stage == "sent" ? "最近照片已接收" : "投递由 Mac 管理", model.photos.last?.deliveryFailed == true ? SnapTheme.failure : SnapTheme.success)
        }.font(SnapTheme.TypeStyle.caption).frame(maxWidth: .infinity)
        }
    }
    private func accessibleNode(_ icon: String, _ name: String, _ detail: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: SnapTheme.Layout.gap) { Image(systemName: icon).font(SnapTheme.TypeStyle.heading).foregroundStyle(color); VStack(alignment: .leading, spacing: SnapTheme.Layout.small) { Text(name).font(SnapTheme.TypeStyle.heading); Text(detail).font(SnapTheme.TypeStyle.caption).foregroundStyle(.secondary) } }
    }
    private func node(_ icon: String, _ name: String, _ detail: String, _ color: Color) -> some View {
        VStack(spacing: SnapTheme.Layout.small) { Image(systemName: icon).foregroundStyle(color).frame(width: SnapTheme.Layout.icon, height: SnapTheme.Layout.icon).background(color.opacity(SnapTheme.Alpha.icon), in: RoundedRectangle(cornerRadius: SnapTheme.Layout.iconRadius)); Text(name).font(SnapTheme.TypeStyle.heading); Text(detail).font(SnapTheme.TypeStyle.micro).foregroundStyle(.secondary).multilineTextAlignment(.center) }.frame(maxWidth: .infinity)
    }
}
struct PairingDigits: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let code: String
    let expires: Date
    var complete = false
    var body: some View {
        VStack(spacing: SnapTheme.Layout.card) {
            Text(complete ? "配对成功" : "验证你的 Mac").font(SnapTheme.TypeStyle.number)
            GeometryReader { geometry in
                HStack(spacing: SnapTheme.Layout.small) {
                    ForEach(Array(code.enumerated()), id: \.offset) { _, digit in Text(String(digit)).foregroundStyle(complete ? SnapTheme.success : .primary).font(SnapTheme.TypeStyle.number).frame(width: min(SnapTheme.Layout.codeWidth, (geometry.size.width - SnapTheme.Layout.small * 5) / 6), height: SnapTheme.Layout.codeHeight).modifier(SnapGlass(radius: SnapTheme.Layout.codeRadius)) }
                }.snapGlassGroup()
            }.frame(height: SnapTheme.Layout.codeHeight)
            TimelineView(.periodic(from: .now, by: 1)) { clock in
                let remaining = max(0, min(60, expires.timeIntervalSince(clock.date)))
                ZStack { Circle().stroke(SnapTheme.waiting.opacity(SnapTheme.Alpha.active), lineWidth: SnapTheme.Layout.ringLine); Circle().trim(from: 0, to: remaining / 60).stroke(SnapTheme.blue, style: StrokeStyle(lineWidth: SnapTheme.Layout.ringLine, lineCap: .round)).rotationEffect(.degrees(SnapTheme.Motion.ringStart)); Text("\(Int(ceil(remaining)))秒").font(SnapTheme.TypeStyle.caption.monospacedDigit()) }.frame(width: SnapTheme.Layout.shutter, height: SnapTheme.Layout.shutter)
            }
            Text("在 Mac 输入这 6 位码\n配对成功后，下次自动连接").font(SnapTheme.TypeStyle.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(SnapTheme.Layout.page).scaleEffect(complete && !reduceMotion ? SnapTheme.Motion.arrival : 1).animation(reduceMotion ? SnapTheme.Motion.fade : SnapTheme.Motion.state, value: complete)
    }
}
struct LessonPhotoViewer: View {
    @ObservedObject var model: PhoneModel
    let photos: [PhonePhoto]
    @State private var currentID: UUID
    @State private var chrome = true
    @Environment(\.dismiss) private var dismiss
    init(model: PhoneModel, photos: [PhonePhoto], initialID: UUID) { self.model = model; self.photos = photos; _currentID = State(initialValue: initialID) }
    private var index: Int { photos.firstIndex { $0.id == currentID } ?? 0 }
    private var current: PhonePhoto? { model.photos.first { $0.id == currentID } ?? photos.first { $0.id == currentID } }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PhotoViewerSurface(photos: photos, selectedID: $currentID, toggle: { withAnimation(SnapTheme.Motion.state) { chrome.toggle() } }, close: { dismiss() }).ignoresSafeArea()
            if chrome {
                VStack {
                    HStack {
                        Button { dismiss() } label: { Image(systemName: "xmark").frame(width: SnapTheme.Layout.touch, height: SnapTheme.Layout.touch) }.modifier(SnapGlass())
                        Spacer(); Text("\(index + 1) / \(photos.count)").font(SnapTheme.TypeStyle.heading.monospacedDigit()).padding(SnapTheme.Layout.small).modifier(SnapGlass()); Spacer()
                        DeliveryRing(photo: current).padding(SnapTheme.Layout.small).modifier(SnapGlass())
                    }.snapGlassGroup()
                    Spacer()
                    VStack(spacing: SnapTheme.Layout.small) {
                        if let photo = current {
                            Text(SnapTheme.date(photo.createdAt)).font(SnapTheme.TypeStyle.caption)
                            Text(photo.statusText(sendingID: model.sendingID)).font(SnapTheme.TypeStyle.body).foregroundStyle(photo.statusColor(sendingID: model.sendingID))
                            HStack { Button("上一张") { currentID = photos[index - 1].id }.disabled(index == 0); Spacer(); ShareLink(item: photo.url) { Image(systemName: "square.and.arrow.up") }; Spacer(); Button("下一张") { currentID = photos[index + 1].id }.disabled(index + 1 >= photos.count) }.font(SnapTheme.TypeStyle.caption)
                            if photo.deliveryFailed { Text("请在 Mac 核对或重发；手机重传不会重复投递 AI。").font(SnapTheme.TypeStyle.micro).foregroundStyle(SnapTheme.failure) }
                            else if !photo.receivedByMac { Button("重试传到 Mac") { model.retry(photo) }.font(SnapTheme.TypeStyle.caption) }
                        }
                        Text("左右切换 · 双击 / 双指缩放 · 下滑关闭").font(SnapTheme.TypeStyle.micro).foregroundStyle(.secondary)
                    }.padding(SnapTheme.Layout.card).modifier(SnapGlass())
                }.padding(SnapTheme.Layout.page).transition(.opacity)
            }
        }.buttonStyle(SnapTouchStyle()).animation(SnapTheme.Motion.state, value: currentID).preferredColorScheme(.dark).tint(.white).toolbar(.hidden, for: .navigationBar)
    }
}

// Surround the existing pager; its paging/zoom implementation is unchanged.
private struct PhotoViewerSurface: UIViewControllerRepresentable {
    let photos: [PhonePhoto]
    @Binding var selectedID: UUID
    var toggle: () -> Void, close: () -> Void
    func makeUIViewController(context: Context) -> PhotoSurfaceController {
        PhotoSurfaceController(root: PhotoPager(photos: photos, selectedID: $selectedID), toggle: toggle, close: close)
    }
    func updateUIViewController(_ controller: PhotoSurfaceController, context: Context) {
        controller.host.rootView = PhotoPager(photos: photos, selectedID: $selectedID)
        controller.toggle = toggle; controller.close = close
        DispatchQueue.main.async { controller.requireDoubleTap() }
    }
}
private final class PhotoSurfaceController: UIViewController, UIGestureRecognizerDelegate {
    let host: UIHostingController<PhotoPager>
    var toggle: () -> Void, close: () -> Void
    private var tap: UITapGestureRecognizer!
    init(root: PhotoPager, toggle: @escaping () -> Void, close: @escaping () -> Void) {
        host = UIHostingController(rootView: root); self.toggle = toggle; self.close = close
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        addChild(host); view.addSubview(host.view); host.didMove(toParent: self)
        tap = UITapGestureRecognizer(target: self, action: #selector(tapped)); tap.cancelsTouchesInView = false; tap.delegate = self
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:))); pan.cancelsTouchesInView = false; pan.delegate = self
        host.view.addGestureRecognizer(tap); host.view.addGestureRecognizer(pan)
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); host.view.frame = view.bounds; requireDoubleTap() }
    func images(_ view: UIView) -> [PhotoScrollView] { (view as? PhotoScrollView).map { [$0] } ?? view.subviews.flatMap(images) }
    func requireDoubleTap() {
        guard isViewLoaded, tap != nil else { return }
        for image in images(host.view) { for recognizer in image.gestureRecognizers ?? [] { if let double = recognizer as? UITapGestureRecognizer, double.numberOfTapsRequired == 2 { tap.require(toFail: double) } } }
    }
    @objc private func tapped() { toggle() }
    @objc private func panned(_ pan: UIPanGestureRecognizer) { if pan.state == .ended, pan.translation(in: host.view).y > SnapTheme.Motion.dismissDistance { close() } }
    func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        if let pan = gesture as? UIPanGestureRecognizer { let v = pan.velocity(in: host.view); return v.y > abs(v.x) && !images(host.view).contains { $0.zoomScale > 1.01 } }
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { gestureRecognizer is UIPanGestureRecognizer }
}
