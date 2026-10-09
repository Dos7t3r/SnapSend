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
    @Namespace private var photoTransition
    init(model: PhoneModel, initialPage: String? = nil) {
        self.model = model; _screen = State(initialValue: initialPage ?? "capture")
        _displayedPairingCode = State(initialValue: model.pairingCode)
    }
    private var captureActive: Bool { screen == "capture" && phase == .active && gallery == nil && !help && !connectionDetails && model.pairingCode == nil && displayedPairingCode == nil }
    private var filtered: [PhonePhoto] { model.photos.filter { (filter != "pending" || !$0.receivedByMac) && (filter != "failed" || $0.deliveryFailed) && (selectedCourse == "all" || $0.context?.lesson.courseID.uuidString == selectedCourse) } }
    private var groups: [String] { var seen = Set<String>(); return filtered.reversed().map(groupID).filter { seen.insert($0).inserted } }
    private func groupID(_ photo: PhonePhoto) -> String { photo.context?.lesson.id.uuidString ?? "inbox-" + photo.createdAt.formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_CN"))) }
    private var courses: [LessonContext] { var ids = Set<UUID>(); return model.photos.compactMap(\.context).filter { ids.insert($0.lesson.courseID).inserted } }
    private func courseColor(_ context: LessonContext?) -> Color { SnapTheme.course[(courses.firstIndex { $0.lesson.courseID == context?.lesson.courseID } ?? 0) % SnapTheme.course.count] }
    var body: some View {
        NavigationStack {
            ZStack {
                SnapBackdrop(paused: screen == "capture")
                Group { if screen == "capture" { capturePage } else if screen == "history" { albumPage } else { settingsPage } }.transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: SnapTheme.Motion.entering)))
            }.frame(maxWidth: .infinity, maxHeight: .infinity).safeAreaInset(edge: .bottom, spacing: SnapTheme.Layout.small) { dock.padding(.horizontal, SnapTheme.Layout.page).padding(.bottom, SnapTheme.Layout.small) }
                .preferredColorScheme(screen == "capture" ? .dark : appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
                .navigationDestination(isPresented: Binding(get: { gallery != nil }, set: { if !$0 { gallery = nil } })) {
                    if let gallery { destination(gallery) }
                }
                .toolbar(.hidden, for: .navigationBar)
        }.environment(\.locale, Locale(identifier: "zh_CN")).tint(SnapTheme.blue)
            .animation(reduceMotion ? .easeOut : SnapTheme.Motion.page, value: screen)
            .onAppear { displayedPairingCode = model.pairingCode; camera.setActive(captureActive) }
            .onChange(of: model.pairingCode) { _, code in if let code { pairingComplete = false; displayedPairingCode = code } else if !model.connected { displayedPairingCode = nil } }
            .onChange(of: model.connected) { _, connected in
                if connected, displayedPairingCode != nil { withAnimation(SnapTheme.Motion.state) { pairingComplete = true }; Task { try? await Task.sleep(for: .seconds(SnapTheme.Motion.flight)); displayedPairingCode = nil } }
            }
            .onChange(of: captureActive) { _, value in camera.setActive(value) }
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
            ZStack(alignment: .top) {
                CameraPreview(camera: camera, volumeEnabled: volumeCapture, shutter: takePhoto, focus: { point in
                    focusPoint = point; focusSmall = false
                    withAnimation(reduceMotion ? .easeOut : SnapTheme.Motion.state) { focusSmall = true }
                }).clipShape(RoundedRectangle(cornerRadius: SnapTheme.Layout.viewfinder))
                if camera.state != .ready { cameraPlaceholder.frame(maxWidth: .infinity, maxHeight: .infinity).background(SnapTheme.dark.opacity(SnapTheme.Alpha.viewfinder), in: RoundedRectangle(cornerRadius: SnapTheme.Layout.viewfinder)) }
                if let point = focusPoint { RoundedRectangle(cornerRadius: SnapTheme.Layout.iconRadius).stroke(.white, lineWidth: SnapTheme.Layout.hairline).frame(width: focusSmall ? SnapTheme.Layout.focusEnd : SnapTheme.Layout.focus, height: focusSmall ? SnapTheme.Layout.focusEnd : SnapTheme.Layout.focus).position(point).allowsHitTesting(false).task(id: point) { try? await Task.sleep(for: .seconds(SnapTheme.Motion.flight)); focusPoint = nil } }
                VStack(spacing: SnapTheme.Layout.small) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: SnapTheme.Layout.small) { connectionPill; targetPill }
                        VStack(alignment: .leading, spacing: SnapTheme.Layout.small) { connectionPill; targetPill }
                    }
                    HStack { Spacer(); Button { flashEnabled.toggle() } label: { Image(systemName: flashEnabled ? "bolt.fill" : "bolt.slash.fill").frame(width: SnapTheme.Layout.touch, height: SnapTheme.Layout.touch) }.modifier(SnapGlass()).accessibilityLabel(flashEnabled ? "关闭闪光灯" : "开启闪光灯"); Button { quality = quality == "清晰" ? "快速" : "清晰" } label: { Label(quality, systemImage: "viewfinder").font(SnapTheme.TypeStyle.micro).padding(SnapTheme.Layout.small).frame(minHeight: SnapTheme.Layout.touch) }.modifier(SnapGlass()).accessibilityLabel("画质：\(quality)，点按切换") }.snapGlassGroup()
                    Spacer()
                    Text(String(format: "%.1f×", camera.zoom)).font(SnapTheme.TypeStyle.caption.monospacedDigit()).padding(SnapTheme.Layout.small).background(.white.opacity(SnapTheme.Alpha.icon), in: Capsule())
                    if let error = model.errorMessage { Text(error).font(SnapTheme.TypeStyle.caption).foregroundStyle(SnapTheme.failure).padding(SnapTheme.Layout.small).modifier(SnapGlass()) }
                    if !model.connected { Text("离线也能拍，连接后自动续传").font(SnapTheme.TypeStyle.micro).foregroundStyle(.white.opacity(SnapTheme.Alpha.secondary)) }
                }.padding(SnapTheme.Layout.card)
                if flash { Color.white.opacity(SnapTheme.Alpha.flash).clipShape(RoundedRectangle(cornerRadius: SnapTheme.Layout.viewfinder)).allowsHitTesting(false) }
                if let id = flightID, let photo = model.photos.first(where: { $0.id == id }), !reduceMotion {
                    PhotoThumbnail(url: photo.url).frame(width: SnapTheme.Layout.flyThumb, height: SnapTheme.Layout.flyThumb).clipped().clipShape(RoundedRectangle(cornerRadius: SnapTheme.Layout.row))
                        .scaleEffect(flying ? SnapTheme.Motion.entering / 2 : 1).position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                        .modifier(CaptureFlight(progress: flying ? 1 : 0, start: CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2), end: CGPoint(x: SnapTheme.Layout.previewThumb, y: geometry.size.height - SnapTheme.Layout.small))).rotationEffect(.degrees(flying ? SnapTheme.Motion.tilt : 0)).allowsHitTesting(false)
                }
            }.padding(SnapTheme.Layout.small)
        }
    }
    private var connectionPill: some View { PhoneConnectionPill(model: model) { connectionDetails = true } }
    private var targetPill: some View {
        HStack(spacing: SnapTheme.Layout.tiny) { Circle().fill(model.activeContext == nil ? SnapTheme.local : courseColor(model.activeContext)).frame(width: SnapTheme.Layout.small, height: SnapTheme.Layout.small); Text(model.activeContext?.displayName ?? "未指定课堂 · 将进收件箱").font(SnapTheme.TypeStyle.micro).lineLimit(1) }.padding(SnapTheme.Layout.small).frame(minHeight: SnapTheme.Layout.touch).modifier(SnapGlass())
    }
    private var cameraPlaceholder: some View {
        VStack(spacing: SnapTheme.Layout.card) {
            Image(systemName: camera.state == .denied ? "camera.badge.ellipsis" : "camera.viewfinder").font(SnapTheme.TypeStyle.title).foregroundStyle(SnapTheme.local)
            Text(cameraMessage).font(SnapTheme.TypeStyle.heading).multilineTextAlignment(.center)
            Text("照片会先保存在手机\n相册和 USB 功能仍可使用").font(SnapTheme.TypeStyle.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if camera.state == .denied { Button("前往系统设置") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }.buttonStyle(.bordered) }
            if case .failed = camera.state { Button("重试相机") { camera.setActive(captureActive) }.buttonStyle(.bordered) }
        }.padding(SnapTheme.Layout.page)
    }
    private var cameraMessage: String {
        switch camera.state { case .preparing: return "正在准备相机"; case .ready: return ""; case .denied: return "允许相机访问，开始记录课堂"; case .unavailable: return "此设备没有可用相机"; case .interrupted: return "相机被暂时中断，结束后自动恢复"; case .failed(let message): return message }
    }
    private func takePhoto() {
        guard camera.state == .ready, camera.captureReady, camera.pending < 2, model.storageReady, model.savingCount < 3 else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred(); flash = true
        Task { try? await Task.sleep(for: .seconds(SnapTheme.Motion.flash)); flash = false }
        let context = model.activeContext, jpegQuality = quality == "快速" ? 0.6 : 0.9
        let orientation = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.interfaceOrientation ?? .portrait
        camera.capture(flash: flashEnabled, fast: quality == "快速", angle: CameraPreview.PreviewSurface.angle(orientation)) { data in model.save(data, context: context, quality: jpegQuality) }
    }
    private func savedFeedback(_ id: UUID?) {
        guard !reduceMotion, let id else { return }; feedbackTask?.cancel(); flying = false; flightID = id
        feedbackTask = Task {
            await Task.yield()
            withAnimation(SnapTheme.Motion.state) { flying = true }
            do { try await Task.sleep(for: .seconds(SnapTheme.Motion.flight)) } catch { return }
            flightID = nil; flying = false
        }
    }
    private var dock: some View {
        HStack(spacing: SnapTheme.Layout.card) {
            if screen == "capture" {
                Button {
                    screen = "history"
                    if let photo = model.photos.last { gallery = PhotoGallerySelection(photo: photo, photos: model.photos) }
                } label: {
                    ZStack(alignment: .bottomTrailing) {
                        Group { if let photo = model.photos.last { PhotoThumbnail(url: photo.url) } else { Image(systemName: "photo.stack").frame(maxWidth: .infinity, maxHeight: .infinity) } }.frame(width: SnapTheme.Layout.previewThumb, height: SnapTheme.Layout.previewThumb).clipped().clipShape(RoundedRectangle(cornerRadius: SnapTheme.Layout.row))
                        DeliveryRing(photo: model.photos.last).background(.white.opacity(SnapTheme.Alpha.soft), in: Circle())
                        Text("\(model.photos.count)").font(SnapTheme.TypeStyle.micro.monospacedDigit()).padding(SnapTheme.Layout.tiny).background(SnapTheme.blue.opacity(SnapTheme.Alpha.active), in: Capsule()).offset(y: -SnapTheme.Layout.previewThumb)
                    }
                }.buttonStyle(.plain).accessibilityLabel("最近照片，打开相册")
                Spacer()
                Button(action: takePhoto) {
                    Circle().fill(SnapTheme.gradient).padding(SnapTheme.Layout.small).overlay(Circle().stroke(.white, lineWidth: SnapTheme.Layout.ringLine)).frame(width: SnapTheme.Layout.shutter, height: SnapTheme.Layout.shutter)
                }.buttonStyle(ShutterStyle()).disabled(camera.state != .ready || !camera.captureReady || camera.pending >= 2 || !model.storageReady || model.savingCount >= 3).accessibilityLabel("拍照并保存")
                Spacer(); dockButton("settings", "设置", "slider.horizontal.3")
            } else {
                dockButton("capture", "拍摄", "camera.fill"); dockButton("history", "相册", "photo.stack"); dockButton("settings", "设置", "slider.horizontal.3")
            }
        }.padding(SnapTheme.Layout.small).frame(minHeight: SnapTheme.Layout.dock).modifier(SnapGlass(radius: SnapTheme.Layout.dock)).snapGlassGroup().dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
    private func dockButton(_ value: String, _ title: String, _ icon: String) -> some View {
        Button { screen = value } label: {
            VStack(spacing: SnapTheme.Layout.tiny) { Image(systemName: icon).font(SnapTheme.TypeStyle.heading); Text(title).font(SnapTheme.TypeStyle.micro).lineLimit(1).fixedSize(horizontal: true, vertical: false) }.frame(maxWidth: .infinity).frame(minHeight: SnapTheme.Layout.touch).padding(SnapTheme.Layout.small)
                .background { if screen == value { Capsule().fill(SnapTheme.gradient).matchedGeometryEffect(id: "dock", in: dockSelection) } }
                .overlay(alignment: .topTrailing) { if value == "history", model.pendingCount > 0 { Text("\(model.pendingCount)").font(SnapTheme.TypeStyle.micro).foregroundStyle(.white).padding(SnapTheme.Layout.tiny).background(SnapTheme.failure, in: Circle()) } }
        }.buttonStyle(.plain).foregroundStyle(screen == value ? .white : .primary)
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
                        }.buttonStyle(.plain)
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
                            Text(photo.createdAt.formatted(.dateTime.hour().minute().locale(Locale(identifier: "zh_CN")))).font(SnapTheme.TypeStyle.micro.monospacedDigit()).lineLimit(1).minimumScaleFactor(SnapTheme.Layout.maxText)
                            Spacer(minLength: 0); DeliveryRing(photo: photo)
                        }.padding(SnapTheme.Layout.tiny).background(.ultraThinMaterial, in: Capsule()).padding(SnapTheme.Layout.tiny)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: SnapTheme.Layout.row))
            }.aspectRatio(SnapTheme.Layout.aspect, contentMode: .fit)
        }.buttonStyle(.plain).accessibilityLabel("\(SnapTheme.date(photo.createdAt))，\(photo.statusText(sendingID: model.sendingID))，查看大图")
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
                    Picker("画质", selection: $quality) { Text("清晰").tag("清晰"); Text("快速").tag("快速") }.pickerStyle(.segmented)
                    Text("清晰保留文字细节；快速缩小文件并优先连拍。原图先保存在手机。").font(SnapTheme.TypeStyle.caption).foregroundStyle(.secondary)
                    Toggle("音量键拍照", isOn: $volumeCapture)
                    Toggle("AI 接收到达触感", isOn: $arrivalHaptics)
                    Text("快门始终有轻触反馈；音量键需 iOS 17.2 及以上。").font(SnapTheme.TypeStyle.micro).foregroundStyle(.secondary)
                }
                settingsCard("外观", "paintpalette", SnapTheme.violet) {
                    Text("主题").font(SnapTheme.TypeStyle.body)
                    Picker("主题", selection: $appearance) { Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark") }.pickerStyle(.segmented)
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
        NavigationStack { ZStack { SnapBackdrop(); ScrollView { VStack(alignment: .leading, spacing: SnapTheme.Layout.card) { Text("连接状态").font(SnapTheme.TypeStyle.title); PhoneChain(model: model); Text(model.status).font(SnapTheme.TypeStyle.body); Text("只有正在传输时保持亮屏，空闲时允许自动锁屏。锁屏或断线后，未同步照片仍在手机。").font(SnapTheme.TypeStyle.caption).foregroundStyle(.secondary); Button("查看使用指南") { connectionDetails = false; help = true } }.padding(SnapTheme.Layout.page) } }.toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { connectionDetails = false } } } }.presentationDetents([.medium, .large])
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
        }
    }
    private func guideRow(_ number: String, _ title: String, _ detail: String) -> some View { HStack(alignment: .top, spacing: SnapTheme.Layout.gap) { Text(number).font(SnapTheme.TypeStyle.heading).foregroundStyle(SnapTheme.blue).frame(width: SnapTheme.Layout.icon, height: SnapTheme.Layout.icon).background(SnapTheme.blue.opacity(SnapTheme.Alpha.icon), in: RoundedRectangle(cornerRadius: SnapTheme.Layout.iconRadius)); VStack(alignment: .leading, spacing: SnapTheme.Layout.small) { Text(title).font(SnapTheme.TypeStyle.heading); Text(detail).font(SnapTheme.TypeStyle.body).foregroundStyle(.secondary) } }.padding(SnapTheme.Layout.card).modifier(SnapGlass()) }
}
private struct ShutterStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.isEnabled) var enabled
    func makeBody(configuration: Configuration) -> some View { configuration.label.opacity(enabled ? 1 : 0.45).scaleEffect(configuration.isPressed && !reduceMotion ? SnapTheme.Motion.shutterScale : 1).animation(reduceMotion ? .easeOut : SnapTheme.Motion.state, value: configuration.isPressed) }
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
