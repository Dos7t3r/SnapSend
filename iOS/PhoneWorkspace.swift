import SwiftUI
import UIKit

struct PhoneView: View {
    @ObservedObject var model: PhoneModel
    @StateObject private var camera = CameraCapture()
    @State var screen = "capture"
    @State private var filter = "all"
    @State private var selectedCourse = "all"
    @State private var gallery: PhotoGallerySelection?
    @State private var help = false
    @State private var connectionDetails = false
    @State private var forget = false
    @State private var flashEnabled = false
    @State private var flash = false
    @AppStorage("SnapSendCaptureToAI") private var captureToAI = true
    @State private var shutterPulse = false
    @State private var thumbnailPulse = false
    @State private var zoomSelection: CGFloat = 1
    @State private var captureFrames: [String: CGRect] = [:]
    @State private var captureMeasurements = CaptureMeasurements()
    @State private var flying = false
    @State private var focusPoint: CGPoint?
    @State private var focusSmall = false
    @State private var displayedPairingCode: String?
    @State private var pairingComplete = false
    @State private var flightID: UUID?
    @State private var feedbackTask: Task<Void, Never>?
    @AppStorage("SnapSendJPEGQuality") private var quality = "清晰"
    @AppStorage("SnapSendAppearance") private var appearance = "system"
    @AppStorage("SnapSendVolumeCapture") private var volumeCapture = true
    @AppStorage("SnapSendArrivalHaptics") private var arrivalHaptics = false
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var dockSelection
    @Namespace private var zoomHighlight
    @Namespace private var photoTransition
    private let cameraOverride: CameraCapture.State?
    private let layoutObserver: (([String: CGRect]) -> Void)?
    init(model: PhoneModel, initialPage: String? = nil, cameraOverride: CameraCapture.State? = nil, camera: CameraCapture? = nil, layoutObserver: (([String: CGRect]) -> Void)? = nil) {
        self.cameraOverride = cameraOverride; self.layoutObserver = layoutObserver
        _camera = StateObject(wrappedValue: camera ?? CameraCapture())
        self.model = model; _screen = State(initialValue: initialPage ?? "capture")
        _displayedPairingCode = State(initialValue: model.pairingCode)
    }
    private var captureState: CameraCapture.State { cameraOverride ?? camera.state }
    private var captureActive: Bool { cameraOverride == nil && screen == "capture" && phase == .active && gallery == nil && !help && !connectionDetails && model.pairingCode == nil && displayedPairingCode == nil }
    private var filtered: [PhonePhoto] { model.photos.filter { (filter != "pending" || !$0.receivedByMac) && (filter != "failed" || $0.deliveryFailed) && (selectedCourse == "all" || $0.context?.lesson.courseID.uuidString == selectedCourse) } }
    private var groups: [String] { var seen = Set<String>(); return filtered.reversed().map(groupID).filter { seen.insert($0).inserted } }
    private func groupID(_ photo: PhonePhoto) -> String { photo.context?.lesson.id.uuidString ?? "inbox-" + photo.createdAt.formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_CN"))) }
    private var courses: [LessonContext] { var ids = Set<UUID>(); return model.photos.compactMap(\.context).filter { ids.insert($0.lesson.courseID).inserted } }
    private func courseColor(_ context: LessonContext?) -> Color { SnapTheme.course[(courses.firstIndex { $0.lesson.courseID == context?.lesson.courseID } ?? 0) % SnapTheme.course.count] }
    var body: some View {
        NavigationStack {
            ZStack {
                SnapBackdrop(paused: screen == "capture")
                VStack(spacing: 0) {
                    Group { if screen == "capture" { capturePage } else if screen == "history" { albumPage } else { settingsPage } }.transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: SnapTheme.Motion.entering)))
                    dock.padding(.horizontal, SnapTheme.Layout.page).padding(.bottom, SnapTheme.Layout.small)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .preferredColorScheme(screen == "capture" ? .dark : appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .navigationDestination(isPresented: Binding(get: { gallery != nil }, set: { if !$0 { gallery = nil } })) {
                    if let gallery { destination(gallery) }
                }
                .toolbar(.hidden, for: .navigationBar)
                .coordinateSpace(name: "capture-root")
                .environment(\.captureFrameObserver, { name, frame in
                    if layoutObserver != nil, captureMeasurements.frames[name] != frame {
                        captureMeasurements.frames[name] = frame; layoutObserver?(captureMeasurements.frames)
                    }
                    // Only two stable centers drive the flight. Scaling a button/ring must not redraw the camera page every frame.
                    if name == "preview" || name == "thumbnail" {
                        let center = CGRect(origin: CGPoint(x: frame.midX, y: frame.midY), size: .zero)
                        if captureFrames[name] != center { captureFrames[name] = center }
                    }
                })
                .overlay {
                    GeometryReader { geometry in
                        let frames = captureFrames
                        if let id = flightID, let photo = model.photos.first(where: { $0.id == id }), let preview = frames["preview"], let thumb = frames["thumbnail"], !reduceMotion {
                            let start = CGPoint(x: preview.midX, y: preview.midY), end = CGPoint(x: thumb.midX, y: thumb.midY)
                            PhotoThumbnail(url: photo.url).frame(width: SnapTheme.Layout.flyThumb, height: SnapTheme.Layout.flyThumb).clipped().clipShape(RoundedRectangle(cornerRadius: 16))
                                .scaleEffect(flying ? 56 / SnapTheme.Layout.flyThumb : 1).position(start)
                                .modifier(CaptureFlight(progress: flying ? 1 : 0, start: start, end: end))
                                .allowsHitTesting(false)
                        }
                    }.allowsHitTesting(false)
                }
        }.environment(\.locale, Locale(identifier: "zh_CN")).tint(SnapTheme.blue).buttonStyle(SnapTouchStyle())
            .animation(reduceMotion ? SnapTheme.Motion.fade : SnapTheme.Motion.page, value: screen)
            .animation(reduceMotion ? SnapTheme.Motion.fade : SnapTheme.Motion.state, value: filter)
            .animation(reduceMotion ? SnapTheme.Motion.fade : SnapTheme.Motion.state, value: selectedCourse)
            .animation(reduceMotion ? SnapTheme.Motion.fade : SnapTheme.Motion.state, value: quality)
            .animation(reduceMotion ? SnapTheme.Motion.fade : SnapTheme.Motion.state, value: model.photos.map { $0.id })
            .onAppear { displayedPairingCode = model.pairingCode; camera.setActive(captureActive) }
            .onChange(of: model.pairingCode) { _, code in if let code { pairingComplete = false; displayedPairingCode = code } else if !model.connected { displayedPairingCode = nil } }
            .onChange(of: model.connected) { _, connected in
                if connected, displayedPairingCode != nil { withAnimation(SnapTheme.Motion.state) { pairingComplete = true }; Task { try? await Task.sleep(for: .seconds(SnapTheme.Motion.flight)); displayedPairingCode = nil } }
            }
            .onChange(of: captureActive) { _, value in camera.setActive(value) }
            .onChange(of: screen) { _, value in if value == "capture" { camera.setZoom(1); zoomSelection = 1 } }
            .onChange(of: camera.zoom) { _, value in zoomSelection = camera.zoomPresets.min(by: { abs($0 - value) < abs($1 - value) }) ?? 1 }
            .onDisappear { camera.setActive(false); feedbackTask?.cancel() }
            .onChange(of: model.lastSavedID) { _, id in savedFeedback(id) }
            .onChange(of: model.aiArrivalID) { _, id in if id != nil, arrivalHaptics { UIImpactFeedbackGenerator(style: .light).impactOccurred() } }
            .sheet(isPresented: $help) { guide }
            .sheet(isPresented: $connectionDetails) { connectionSheet }
            .sheet(isPresented: Binding(get: { displayedPairingCode != nil }, set: { _ in })) { if let code = displayedPairingCode { ZStack { SnapBackdrop(); PairingDigits(code: code, expires: model.pairingExpiresAt ?? Date(), complete: pairingComplete) }.interactiveDismissDisabled().presentationDetents([.medium]) } }
    }
    @ViewBuilder private func destination(_ selection: PhotoGallerySelection) -> some View {
        if #available(iOS 18, *), !reduceMotion { LessonPhotoViewer(model: model, photos: selection.photos, initialID: selection.id).navigationTransition(.zoom(sourceID: selection.id, in: photoTransition)) }
        else { LessonPhotoViewer(model: model, photos: selection.photos, initialID: selection.id) }
    }
    @ViewBuilder private func source<V: View>(_ view: V, id: UUID) -> some View { if #available(iOS 18, *) { view.matchedTransitionSource(id: id, in: photoTransition) } else { view } }
    private var capturePage: some View {
        GeometryReader { geometry in
            // A 4:3 sensor rotates to a 3:4 portrait image; shrink both axes together on short screens.
            let size = SnapTheme.CaptureLayout.preview(in: geometry.size)
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    PhoneConnectionPill(model: model, compact: true) { connectionDetails = true }
                        .frame(maxWidth: (geometry.size.width - 32) * 0.55, alignment: .leading).captureAnchor("connection")
                    Spacer(minLength: 0)
                    targetPill
                }.frame(height: 44).padding(.horizontal, 16).captureAnchor("top")
                ZStack {
                    CameraPreview(camera: camera, volumeEnabled: volumeCapture, shutter: takePhoto, focus: { point in
                        focusPoint = point; focusSmall = false
                        withAnimation(reduceMotion ? SnapTheme.Motion.fade : SnapTheme.Motion.state) { focusSmall = true }
                    })
                    if captureState != .ready { cameraPlaceholder.frame(maxWidth: .infinity, maxHeight: .infinity).transition(.opacity).background(LinearGradient(colors: SnapTheme.darkMesh, startPoint: .topLeading, endPoint: .bottomTrailing).allowsHitTesting(false)) }
                    if let point = focusPoint { RoundedRectangle(cornerRadius: SnapTheme.Layout.iconRadius).stroke(.white, lineWidth: 1).frame(width: focusSmall ? 44 : 64, height: focusSmall ? 44 : 64).position(point).allowsHitTesting(false).task(id: point) { try? await Task.sleep(for: .seconds(SnapTheme.Motion.flight)); focusPoint = nil } }
                    if flash { Color.white.opacity(SnapTheme.Alpha.flash).allowsHitTesting(false) }
                }.animation(SnapTheme.Motion.fade, value: captureState).frame(width: size.width, height: size.height).clipShape(RoundedRectangle(cornerRadius: 28)).captureAnchor("preview").padding(.top, 12)
                captureControls.frame(height: 44).captureAnchor("controls").padding(.top, 12)
                Button { withAnimation(reduceMotion ? SnapTheme.Motion.fade : SnapTheme.Motion.state) { captureToAI.toggle() } } label: {
                    Label(captureToAI ? "课堂照片 · 允许发送到 AI" : "私人照片 · 仅保存到手机和 Mac", systemImage: captureToAI ? "paperplane" : "lock.fill")
                        .font(SnapTheme.TypeStyle.micro).frame(maxWidth: .infinity, minHeight: 44).foregroundStyle(captureToAI ? .white : SnapTheme.local)
                }.accessibilityHint("拍摄前切换；此选择会随每张照片保存，不会因重新连接改变")
                if let error = model.errorMessage { Text(error).font(SnapTheme.TypeStyle.micro).foregroundStyle(SnapTheme.failure).lineLimit(2).padding(.top, 8) }
                Spacer(minLength: 0)
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .top).dynamicTypeSize(...DynamicTypeSize.large)
        }
    }
    private var connectionPill: some View { PhoneConnectionPill(model: model) { connectionDetails = true } }
    private var targetPill: some View {
        HStack(spacing: 5) {
            Image(systemName: "book.closed.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).frame(width: 20, height: 20)
                .background(model.activeContext == nil ? SnapTheme.local : courseColor(model.activeContext), in: RoundedRectangle(cornerRadius: 6))
            Text(model.activeContext?.displayName ?? "未指定课堂").font(SnapTheme.TypeStyle.micro).lineLimit(1).truncationMode(.tail)
        }.foregroundStyle(model.activeContext == nil ? SnapTheme.local : .white).padding(.horizontal, 8).frame(height: 36)
            .background(model.activeContext == nil ? SnapTheme.local.opacity(0.16) : .white.opacity(0.08), in: Capsule()).captureAnchor("target")
    }
    private var captureControls: some View {
        HStack(spacing: 6) {
            Button { withAnimation(reduceMotion ? SnapTheme.Motion.fade : SnapTheme.Motion.state) { flashEnabled.toggle() } } label: {
                Image(systemName: flashEnabled ? "bolt.fill" : "bolt.slash.fill").contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace)).frame(width: 44, height: 44).modifier(SnapGlass(radius: 22))
            }.captureAnchor("flash-button").accessibilityLabel(flashEnabled ? "关闭闪光灯" : "开启闪光灯")
            HStack(spacing: 0) {
                ForEach(camera.zoomPresets, id: \.self) { value in
                    Button { withAnimation(SnapTheme.Motion.state) { zoomSelection = value }; camera.setZoom(value) } label: {
                        Text(zoomSelection == value && abs(camera.zoom - value) > 0.05 ? String(format: "%.1f×", camera.zoom) : String(format: "%g×", Double(value)))
                            .font(SnapTheme.TypeStyle.micro.monospacedDigit()).contentTransition(.numericText()).animation(reduceMotion ? SnapTheme.Motion.fade : SnapTheme.Motion.state, value: camera.zoom).frame(width: 44, height: 44)
                            .background { if zoomSelection == value { Capsule().fill(SnapTheme.gradient).snapSelection(id: "zoom", namespace: zoomHighlight, reduced: reduceMotion).allowsHitTesting(false) } }
                    }.captureAnchor("zoom-\(value)").accessibilityLabel("变焦 \(value) 倍")
                }
            }.modifier(SnapGlass(radius: 22)).animation(reduceMotion ? SnapTheme.Motion.fade : SnapTheme.Motion.state, value: zoomSelection)
            Button { withAnimation(SnapTheme.Motion.state) { quality = quality == "清晰" ? "快速" : "清晰" } } label: {
                HStack(spacing: 3) { Image(systemName: "viewfinder"); Text(quality) }.font(SnapTheme.TypeStyle.micro).frame(minWidth: 60, minHeight: 44).modifier(SnapGlass(radius: 22))
            }.captureAnchor("quality-button").accessibilityLabel("画质：\(quality)，点按切换")
        }.frame(maxWidth: .infinity).padding(.horizontal, 12)
    }
    private var cameraPlaceholder: some View {
        VStack(spacing: SnapTheme.Layout.card) {
            Image(systemName: captureState == .denied ? "camera.badge.ellipsis" : "camera.viewfinder").font(SnapTheme.TypeStyle.title).foregroundStyle(SnapTheme.local)
            Text(cameraMessage).font(SnapTheme.TypeStyle.heading).multilineTextAlignment(.center)
            Text("照片会先保存在手机\n相册和 USB 功能仍可使用").font(SnapTheme.TypeStyle.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if captureState == .denied { Button("前往系统设置") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }.buttonStyle(SnapTouchStyle()) }
            if case .failed = captureState { Button("重试相机") { camera.setActive(captureActive) }.buttonStyle(SnapTouchStyle()) }
        }.padding(SnapTheme.Layout.page)
    }
    private var cameraMessage: String {
        switch captureState { case .preparing: return "正在准备相机"; case .ready: return ""; case .denied: return "允许相机访问，开始记录课堂"; case .unavailable: return "此设备没有可用相机"; case .interrupted: return "相机被暂时中断，结束后自动恢复"; case .failed(let message): return message }
    }
    private func takePhoto() {
        guard camera.state == .ready, camera.captureReady, camera.pending < 2, model.storageReady, model.savingCount < 3 else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred(); flash = true
        withAnimation(reduceMotion ? SnapTheme.Motion.fade : SnapTheme.Motion.press) { shutterPulse = true }
        Task { try? await Task.sleep(for: .seconds(SnapTheme.Motion.flash)); withAnimation(reduceMotion ? SnapTheme.Motion.fade : SnapTheme.Motion.state) { shutterPulse = false } }
        Task { try? await Task.sleep(for: .seconds(SnapTheme.Motion.flash)); flash = false }
        let sendToAI = captureToAI
        let context = model.activeContext, jpegQuality = quality == "快速" ? 0.6 : 0.9
        let orientation = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.interfaceOrientation ?? .portrait
        camera.capture(flash: flashEnabled, fast: quality == "快速", angle: CameraPreview.PreviewSurface.angle(orientation)) { data in model.save(data, context: context, quality: jpegQuality, sendToAI: sendToAI) }
    }
    private func savedFeedback(_ id: UUID?) {
        guard !reduceMotion, let id else { return }; feedbackTask?.cancel(); flying = false; flightID = id
        feedbackTask = Task {
            await Task.yield()
            withAnimation(SnapTheme.Motion.state) { flying = true }
            do { try await Task.sleep(for: .seconds(SnapTheme.Motion.flight)) } catch { return }
            withAnimation(SnapTheme.Motion.state) { thumbnailPulse = true }; flightID = nil; flying = false
            try? await Task.sleep(for: .seconds(SnapTheme.Motion.flight / 2)); withAnimation(SnapTheme.Motion.state) { thumbnailPulse = false }
        }
    }
    private var dock: some View {
        Group {
            if screen == "capture" {
                ZStack {
                    Button(action: takePhoto) {
                        ZStack {
                            Circle().fill(SnapTheme.gradient).padding(7).scaleEffect(shutterPulse && !reduceMotion ? SnapTheme.Motion.innerShutter : 1)
                            Circle().fill(LinearGradient(colors: [.white.opacity(0.16), .clear], startPoint: .top, endPoint: .center)).padding(7).allowsHitTesting(false)
                            Circle().strokeBorder(.white, lineWidth: 4).allowsHitTesting(false)
                        }.frame(width: 76, height: 76)
                    }.buttonStyle(ShutterStyle()).disabled(captureState != .ready || !camera.captureReady || camera.pending >= 2 || !model.storageReady || model.savingCount >= 3).accessibilityLabel("拍照并保存").captureAnchor("shutter")
                    HStack {
                        Button {
                            screen = "history"
                            if let photo = model.photos.last { gallery = PhotoGallerySelection(photo: photo, photos: model.photos) }
                        } label: {
                            ZStack {
                                Group { if let photo = model.photos.last { PhotoThumbnail(url: photo.url) } else { Image(systemName: "photo.stack").frame(maxWidth: .infinity, maxHeight: .infinity) } }
                                    .frame(width: 56, height: 56).clipped().clipShape(RoundedRectangle(cornerRadius: 16)).captureAnchor("thumbnail")
                                DeliveryRing(photo: model.photos.last, thumbnail: true).allowsHitTesting(false)
                            }.frame(width: 64, height: 64).overlay(alignment: .topTrailing) {
                                Text("\(model.photos.count)").contentTransition(.numericText()).font(SnapTheme.TypeStyle.micro.monospacedDigit().bold()).foregroundStyle(SnapTheme.ink).padding(.horizontal, 5).padding(.vertical, 3).background(.white, in: Capsule()).offset(x: 5, y: -5).allowsHitTesting(false)
                            }.scaleEffect(thumbnailPulse && !reduceMotion ? SnapTheme.Motion.arrival : 1)
                        }.buttonStyle(SnapTouchStyle(radius: 20, hitSlop: 5)).captureAnchor("album-button").accessibilityLabel("最近照片，打开相册")
                        Spacer(minLength: 0)
                        Button { screen = "settings" } label: { Image(systemName: "slider.horizontal.3").font(SnapTheme.TypeStyle.heading).frame(width: 56, height: 56).modifier(SnapGlass(radius: 28)).frame(width: 64, height: 64) }.captureAnchor("settings-button").accessibilityLabel("设置")
                    }.padding(.horizontal, 12)
                }
            } else {
                HStack(spacing: SnapTheme.Layout.card) { dockButton("capture", "拍摄", "camera.fill"); dockButton("history", "相册", "photo.stack"); dockButton("settings", "设置", "slider.horizontal.3") }
            }
        }.frame(height: 88).frame(maxWidth: .infinity).modifier(SnapGlass(radius: 44)).captureAnchor("dock").dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
    private func dockButton(_ value: String, _ title: String, _ icon: String) -> some View {
        Button { screen = value } label: {
            VStack(spacing: SnapTheme.Layout.tiny) { Image(systemName: icon).font(SnapTheme.TypeStyle.heading); Text(title).font(SnapTheme.TypeStyle.micro).lineLimit(1).fixedSize(horizontal: true, vertical: false) }.frame(maxWidth: .infinity).frame(minHeight: SnapTheme.Layout.touch).padding(SnapTheme.Layout.small)
                .background { if screen == value { Capsule().fill(SnapTheme.gradient).snapSelection(id: "dock", namespace: dockSelection, reduced: reduceMotion).allowsHitTesting(false) } }
                .overlay(alignment: .topTrailing) { if value == "history", model.pendingCount > 0 { Text("\(model.pendingCount)").font(SnapTheme.TypeStyle.micro).foregroundStyle(.white).padding(SnapTheme.Layout.tiny).background(SnapTheme.failure, in: Circle()).allowsHitTesting(false) } }
        }.buttonStyle(SnapTouchStyle()).foregroundStyle(screen == value ? .white : .primary)
    }
    private var albumPage: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: SnapTheme.Layout.gap, pinnedViews: [.sectionHeaders]) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top) { albumTitle; Spacer(); connectionPill }
                    VStack(alignment: .leading, spacing: SnapTheme.Layout.small) { albumTitle; connectionPill }
                }.padding(.top, SnapTheme.Layout.small)
                HStack(spacing: SnapTheme.Layout.small) {
                    ForEach(["all", "pending", "failed"], id: \.self) { value in
                        Button { filter = value } label: {
                            Text(value == "all" ? "全部" : value == "pending" ? "待传输" : "失败").font(SnapTheme.TypeStyle.caption).lineLimit(1).fixedSize(horizontal: true, vertical: false).frame(maxWidth: .infinity).frame(minHeight: SnapTheme.Layout.touch)
                                .background(SnapTheme.blue.opacity(filter == value ? 0.2 : 0), in: Capsule())
                        }.buttonStyle(SnapTouchStyle())
                    }
                    Menu { Button("全部课程") { selectedCourse = "all" }; ForEach(courses, id: \.lesson.courseID) { context in Button(context.courseName) { selectedCourse = context.lesson.courseID.uuidString } } } label: { Image(systemName: "line.3.horizontal.decrease").frame(width: SnapTheme.Layout.touch, height: SnapTheme.Layout.touch) }.accessibilityLabel("课程筛选")
                }.padding(SnapTheme.Layout.small).modifier(SnapGlass()).dynamicTypeSize(...DynamicTypeSize.large)
                if filtered.isEmpty {
                    VStack(spacing: SnapTheme.Layout.card) { Image(systemName: "photo.stack").font(SnapTheme.TypeStyle.title).foregroundStyle(SnapTheme.violet); Text(model.photos.isEmpty ? "这里会留下你的课堂" : "没有符合筛选的照片").font(SnapTheme.TypeStyle.heading); Text("离线可拍摄，原图先保存\n连接 Mac 后继续传输").font(SnapTheme.TypeStyle.body).foregroundStyle(.secondary).multilineTextAlignment(.center) }.frame(maxWidth: .infinity).padding(.vertical, SnapTheme.Layout.shutter)
                }
                ForEach(groups, id: \.self) { id in
                    let photos = filtered.filter { groupID($0) == id }
                    Section {
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: SnapTheme.Layout.gap) {
                            ForEach(photos.reversed()) { photo in source(photoTile(photo, photos), id: photo.id) }
                        }
                    } header: {
                        HStack(spacing: SnapTheme.Layout.small) { Circle().fill(courseColor(photos.first?.context)).frame(width: SnapTheme.Layout.small, height: SnapTheme.Layout.small); VStack(alignment: .leading, spacing: SnapTheme.Layout.tiny) { Text(photos.first?.context?.displayName ?? "收件箱 · 未分配").font(SnapTheme.TypeStyle.heading); Text("\(SnapTheme.date(photos.first?.createdAt ?? Date())) · \(photos.count) 张").font(SnapTheme.TypeStyle.micro).foregroundStyle(.secondary) }; Spacer() }.padding(SnapTheme.Layout.card).modifier(SnapGlass())
                    }
                }
            }.padding(SnapTheme.Layout.page)
        }
    }
    private var albumTitle: some View {
        VStack(alignment: .leading, spacing: SnapTheme.Layout.small) { Text("课堂相册").font(SnapTheme.TypeStyle.title).lineLimit(1).fixedSize(horizontal: true, vertical: false); Text(SnapTheme.date(Date(), time: false)).font(SnapTheme.TypeStyle.caption).foregroundStyle(.secondary) }
    }
    private func photoTile(_ photo: PhonePhoto, _ photos: [PhonePhoto]) -> some View {
        Button { gallery = PhotoGallerySelection(photo: photo, photos: photos) } label: {
            GeometryReader { g in
                PhotoThumbnail(url: photo.url).frame(width: g.size.width, height: g.size.height).clipped()
                    .overlay(alignment: .bottom) {
                        HStack(spacing: SnapTheme.Layout.tiny) {
                            Text(SnapTheme.date(photo.createdAt)).font(SnapTheme.TypeStyle.micro.monospacedDigit()).lineLimit(1).minimumScaleFactor(SnapTheme.Layout.maxText)
                            Spacer(minLength: 0); DeliveryRing(photo: photo)
                        }.padding(SnapTheme.Layout.tiny).background(.ultraThinMaterial, in: Capsule()).padding(SnapTheme.Layout.tiny).allowsHitTesting(false)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: SnapTheme.Layout.row))
            }.aspectRatio(SnapTheme.Layout.aspect, contentMode: .fit)
        }.buttonStyle(SnapTouchStyle()).accessibilityLabel("\(SnapTheme.date(photo.createdAt))，\(photo.statusText(sendingID: model.sendingID))，查看大图")
            .transition(reduceMotion ? .opacity : .scale(scale: SnapTheme.Motion.entering).combined(with: .opacity))
    }
    private var settingsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: SnapTheme.Layout.gap) {
                HStack(spacing: SnapTheme.Layout.gap) { SnapMark(); Text("设置").font(SnapTheme.TypeStyle.title); Spacer() }
                settingsCard("连接", "cable.connector", SnapTheme.cyan) {
                    PhoneChain(model: model)
                    Text(model.pairedPeerName.isEmpty ? "尚未配对电脑" : "已配对：\(model.pairedPeerName)").font(SnapTheme.TypeStyle.body)
                    Button("使用指南") { help = true }
                    Button("忘记已配对电脑", role: .destructive) { forget = true }
                }
                settingsCard("拍摄", "camera.aperture", SnapTheme.local) {
                    Text("画质").font(SnapTheme.TypeStyle.body)
                    SnapSegments(values: ["清晰", "快速"], titles: ["清晰", "快速"], selection: $quality)
                    Text("清晰保留文字细节；快速缩小文件并优先连拍。原图先保存在手机。").font(SnapTheme.TypeStyle.caption).foregroundStyle(.secondary)
                    SnapToggle(title: "音量键拍照", isOn: $volumeCapture)
                    SnapToggle(title: "AI 接收到达触感", isOn: $arrivalHaptics)
                    Text("快门始终有轻触反馈；音量键需 iOS 17.2 及以上。").font(SnapTheme.TypeStyle.micro).foregroundStyle(.secondary)
                }
                settingsCard("外观", "paintpalette", SnapTheme.violet) {
                    Text("主题").font(SnapTheme.TypeStyle.body)
                    SnapSegments(values: ["system", "light", "dark"], titles: ["跟随系统", "浅色", "深色"], selection: $appearance)
                    Text("拍摄页始终使用深色，方便专注取景。").font(SnapTheme.TypeStyle.caption).foregroundStyle(.secondary)
                }
                settingsCard("本地照片", "photo.stack", SnapTheme.success) {
                    HStack { metric("已保存", model.photos.count); Spacer(); metric("等待传到 Mac", model.pendingCount) }
                    Text("USB 传完后，手机照片仍保留。可以在相册翻页、缩放和导出。").font(SnapTheme.TypeStyle.caption).foregroundStyle(.secondary)
                }
                if let error = model.errorMessage { Text(error).foregroundStyle(SnapTheme.failure).font(SnapTheme.TypeStyle.caption) }
                Text("SnapSend \(SnapSendVersion) · 构建 \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "")").font(SnapTheme.TypeStyle.micro).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, SnapTheme.Layout.page)
            }.padding(SnapTheme.Layout.page)
        }.alert("忘记已配对电脑？", isPresented: $forget) { Button("取消", role: .cancel) {}; Button("忘记设备", role: .destructive) { model.forgetPairings() } } message: { Text("照片不会删除，下次连接需要重新验证。") }
    }
    private func settingsCard<V: View>(_ title: String, _ icon: String, _ color: Color, @ViewBuilder content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: SnapTheme.Layout.card) { HStack { Image(systemName: icon).foregroundStyle(color).frame(width: SnapTheme.Layout.icon, height: SnapTheme.Layout.icon).background(color.opacity(SnapTheme.Alpha.icon), in: RoundedRectangle(cornerRadius: SnapTheme.Layout.iconRadius)); Text(title).font(SnapTheme.TypeStyle.heading) }; content().font(SnapTheme.TypeStyle.body) }.padding(SnapTheme.Layout.card).frame(maxWidth: .infinity, alignment: .leading).modifier(SnapGlass())
    }
    private func metric(_ title: String, _ value: Int) -> some View { VStack(alignment: .leading, spacing: SnapTheme.Layout.small) { Text("\(value)").font(SnapTheme.TypeStyle.number).contentTransition(.numericText()); Text(title).font(SnapTheme.TypeStyle.caption).foregroundStyle(.secondary) }.animation(SnapTheme.Motion.state, value: value) }
    private var connectionSheet: some View {
        NavigationStack { ZStack { SnapBackdrop(); ScrollView { VStack(alignment: .leading, spacing: SnapTheme.Layout.card) { Text("连接状态").font(SnapTheme.TypeStyle.title); PhoneChain(model: model); Text(model.status).font(SnapTheme.TypeStyle.body); Text("只有正在传输时保持亮屏，空闲时允许自动锁屏。锁屏或断线后，未同步照片仍在手机。").font(SnapTheme.TypeStyle.caption).foregroundStyle(.secondary); Button("查看使用指南") { connectionDetails = false; help = true } }.padding(SnapTheme.Layout.page) } }.toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { connectionDetails = false } } } }.buttonStyle(SnapTouchStyle()).presentationDetents([.medium, .large])
    }
    private var guide: some View {
        NavigationStack {
            ZStack { SnapBackdrop(); ScrollView { VStack(alignment: .leading, spacing: SnapTheme.Layout.card) {
                SnapMark(size: SnapTheme.Layout.shutter); Text("拍下课堂，留给自己").font(SnapTheme.TypeStyle.title)
                guideRow("1", "连接 Mac", "用数据线连接，解锁 iPhone 并打开 SnapSend。无需个人热点或校园网。")
                guideRow("2", "选择发送目标", "在 Mac 选择课程与 Section；未指定时照片进入收件箱，随时可分配。")
                guideRow("3", "拍下这一页", "打开即取景，轻点快门直接保存，不需要确认。先保存，再通过 USB 传到 Mac。")
                guideRow("4", "让 AI 记录", "在 Mac 配置 AI 投递，在 Chrome 专用聊天中绑定并开启自动发送。投递不确定时，请在 Mac 核对。")
                Text("离线拍摄会继续保存。App 在后台时 USB 和相机会暂停，回到前台恢复。").font(SnapTheme.TypeStyle.caption).foregroundStyle(.secondary)
            }.padding(SnapTheme.Layout.page) } }.toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { help = false } } }
        }.buttonStyle(SnapTouchStyle())
    }
    private func guideRow(_ number: String, _ title: String, _ detail: String) -> some View { HStack(alignment: .top, spacing: SnapTheme.Layout.gap) { Text(number).font(SnapTheme.TypeStyle.heading).foregroundStyle(SnapTheme.blue).frame(width: SnapTheme.Layout.icon, height: SnapTheme.Layout.icon).background(SnapTheme.blue.opacity(SnapTheme.Alpha.icon), in: RoundedRectangle(cornerRadius: SnapTheme.Layout.iconRadius)); VStack(alignment: .leading, spacing: SnapTheme.Layout.small) { Text(title).font(SnapTheme.TypeStyle.heading); Text(detail).font(SnapTheme.TypeStyle.body).foregroundStyle(.secondary) } }.padding(SnapTheme.Layout.card).modifier(SnapGlass()) }
}
private struct ShutterStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.isEnabled) var enabled
    func makeBody(configuration: Configuration) -> some View { configuration.label.contentShape(Circle()).opacity(enabled ? 1 : 0.45).scaleEffect(configuration.isPressed && !reduceMotion ? SnapTheme.Motion.shutterScale : 1).animation(reduceMotion ? .easeOut : SnapTheme.Motion.state, value: configuration.isPressed) }
}

private struct CaptureFlight: GeometryEffect {
    var progress: CGFloat
    var start: CGPoint, end: CGPoint
    var animatableData: CGFloat { get { progress } set { progress = newValue } }
    func effectValue(size: CGSize) -> ProjectionTransform {
        let p = progress, q = 1 - p
        let control = CGPoint(x: start.x - SnapTheme.Layout.flightHeight, y: start.y - SnapTheme.Layout.flightHeight)
        let x = q * q * start.x + 2 * q * p * control.x + p * p * end.x
        let y = q * q * start.y + 2 * q * p * control.y + p * p * end.y
        return ProjectionTransform(CGAffineTransform(translationX: x - start.x, y: y - start.y))
    }
}

private final class CaptureMeasurements { var frames: [String: CGRect] = [:] }

// Direct geometry observation crosses native button/glass containers; anchor preferences do not.
private struct CaptureFrameObserver: EnvironmentKey {
    static let defaultValue: ((String, CGRect) -> Void)? = nil
}
private extension EnvironmentValues {
    var captureFrameObserver: ((String, CGRect) -> Void)? {
        get { self[CaptureFrameObserver.self] }
        set { self[CaptureFrameObserver.self] = newValue }
    }
}
private struct CaptureFrame: ViewModifier {
    let name: String
    @Environment(\.captureFrameObserver) private var observer
    func body(content: Content) -> some View {
        content.background {
            GeometryReader { geometry in
                let frame = geometry.frame(in: .named("capture-root"))
                Color.clear.onChange(of: frame, initial: true) { _, frame in observer?(name, frame) }
            }.allowsHitTesting(false)
        }
    }
}
private extension View {
    func captureAnchor(_ name: String) -> some View { modifier(CaptureFrame(name: name)) }
}
