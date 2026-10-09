import SwiftUI
import AppKit
import SnapSendCore

enum WorkspacePage: String, CaseIterable {
    case overview = "概览", courses = "课程", inbox = "收件箱", tasks = "发送任务", settings = "设置"
    var symbol: String { switch self { case .overview: "square.grid.2x2.fill"; case .courses: "folder.fill"; case .inbox: "tray.fill"; case .tasks: "paperplane.fill"; case .settings: "slider.horizontal.3" } }
    var color: Color { switch self { case .overview: Aurora.Colors.blue; case .courses: Aurora.Colors.target; case .inbox: Aurora.Colors.phone; case .tasks: Aurora.Colors.bridge; case .settings: Aurora.Colors.bridge } }
}
struct WorkspaceView: View {
    @ObservedObject var model: WorkspaceModel
    @State var page: WorkspacePage = .overview
    @State private var showingHistory = false
    @State private var courseName = ""
    @State private var preview: UUID?
    @State private var targetPicker = false
    @State private var deletingPhoto = false
    @Namespace private var navigation
    @Environment(\.auroraReduceMotion) private var reduceMotion
    init(model: WorkspaceModel, page: WorkspacePage = .overview, history: Bool = false) {
        self.model = model; _page = State(initialValue: page); _showingHistory = State(initialValue: history)
    }
    var body: some View {
        ZStack {
            AuroraBackground()
            HStack(spacing: Aurora.Space.gap) {
                sidebar.frame(width: Aurora.Space.sidebar).padding(.leading, Aurora.Space.inset).padding(.vertical, Aurora.Space.inset)
                VStack(alignment: .leading, spacing: Aurora.Space.inset) {
                    if let banner = model.alertBanner { bannerView(banner) }
                    Group {
                        switch page {
                        case .overview:
                            if showingHistory { HistoryScreen(model: model, openPhoto: openPhoto, back: { showingHistory = false }) }
                            else { OverviewScreen(model: model, configure: { page = .settings }, changeTarget: { targetPicker = true }, openPhoto: openPhoto, showHistory: { page = .tasks }) }
                        case .courses: CoursesScreen(model: model, openPhoto: openPhoto)
                        case .inbox: InboxScreen(model: model, openPhoto: openPhoto)
                        case .tasks: HistoryScreen(model: model, openPhoto: openPhoto, back: { page = .overview })
                        case .settings: SettingsScreen(model: model)
                        }
                    }.id(page.rawValue + String(showingHistory)).transition(reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: Aurora.Motion.pageIn)), removal: .opacity.combined(with: .offset(y: Aurora.Motion.pageOut))))
                }.padding(.vertical, Aurora.Space.page).frame(maxWidth: .infinity, maxHeight: .infinity)
            }.auroraGlassGroup()
        }.foregroundStyle(Aurora.Colors.primary).font(Aurora.TypeStyle.body).tint(Aurora.Colors.blue)
            .environment(\.locale, Locale(identifier: "zh_CN")).preferredColorScheme(.dark)
            .animation(reduceMotion ? Aurora.Motion.fade : Aurora.Motion.page, value: page)
            .animation(reduceMotion ? Aurora.Motion.fade : Aurora.Motion.page, value: showingHistory)
            .buttonStyle(PressableStyle(inset: Aurora.Space.tiny))
            .sheet(isPresented: $targetPicker) { targetSheet }
            .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) { photoPreview }
            .alert("新建课程", isPresented: $model.showingNewCourseAlert) {
                TextField("课程名称，例如 STA256", text: $courseName); Button("取消", role: .cancel) {}; Button("创建") { model.createCourse(courseName); courseName = "" }.disabled(courseName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } message: { Text("创建默认 Section，随后设置名称、课表和聊天。无需开课就能拍照。") }
    }
    private func openPhoto(_ photo: PhotoRecord) { model.selected = photo.id; preview = photo.id }
    private var sidebar: some View {
        ScrollView { VStack(alignment: .leading, spacing: Aurora.Space.gap) {
            HStack(spacing: Aurora.Space.inset) { SnapMark(size: Aurora.Space.icon); Text("SnapSend").font(Aurora.TypeStyle.heading) }.padding(.top, Aurora.Space.page)
            VStack(spacing: Aurora.Space.small) {
                ForEach(WorkspacePage.allCases, id: \.self) { item in
                    Button { showingHistory = false; page = item } label: {
                        HStack(spacing: Aurora.Space.inset) {
                            Image(systemName: item.symbol).font(Aurora.TypeStyle.heading).foregroundStyle(page == item ? Aurora.Colors.primary : item.color).selectionBounce(page == item).frame(width: Aurora.Space.page, height: Aurora.Space.page).background(item.color.opacity(page == item ? Aurora.Alpha.active : Aurora.Alpha.icon), in: RoundedRectangle(cornerRadius: Aurora.Space.iconRadius))
                            Text(item.rawValue).font(Aurora.TypeStyle.body.weight(.semibold)); Spacer()
                            if item == .inbox, !model.pendingPhotos.isEmpty { Text("\(model.pendingPhotos.count)").font(Aurora.TypeStyle.micro).monospacedDigit().contentTransition(reduceMotion ? .opacity : .numericText()).animation(reduceMotion ? Aurora.Motion.fade : Aurora.Motion.state, value: model.pendingPhotos.count) }
                        }.padding(.horizontal, Aurora.Space.inset).frame(height: Aurora.Space.nav)
                            .frame(maxWidth: .infinity, alignment: .leading).background { if page == item { RoundedRectangle(cornerRadius: Aurora.Space.rowRadius).fill(Aurora.Colors.selected).matchedGeometryEffect(id: "navigation", in: navigation).allowsHitTesting(false) } }
                    }.buttonStyle(PressableStyle(row: true))
                }
            }
        }.padding(Aurora.Space.card) }.scrollIndicators(.automatic)
        .safeAreaInset(edge: .bottom, spacing: 0) { VStack(alignment: .leading, spacing: Aurora.Space.small) {
            Text("照片先保存，再发送").font(Aurora.TypeStyle.micro).foregroundStyle(Aurora.Colors.tertiary)
            Button { page = .settings } label: {
                HStack(spacing: Aurora.Space.small) {
                    Circle().fill(model.usbConnected ? Aurora.Colors.success : Aurora.Colors.queued).frame(width: Aurora.Space.small, height: Aurora.Space.small)
                    VStack(alignment: .leading, spacing: Aurora.Space.tiny) { Text((model.usbMode == "pad" ? "iPad" : "iPhone") + (model.usbConnected ? " · USB 已连接" : " · 等待连接")).font(Aurora.TypeStyle.caption); Text("连接与配对").font(Aurora.TypeStyle.micro).foregroundStyle(Aurora.Colors.secondary) }
                }.padding(Aurora.Space.inset).frame(maxWidth: .infinity, alignment: .leading).background(Aurora.Colors.white.opacity(Aurora.Alpha.hover), in: Capsule())
            }.buttonStyle(PressableStyle(radius: 40, row: true))
        }.padding(Aurora.Space.card) }.glassCard(cornerRadius: Aurora.Space.sidebarRadius)
    }
    private var targetSheet: some View {
        VStack(alignment: .leading, spacing: Aurora.Space.gap) {
            Text("选择发送目标").font(Aurora.TypeStyle.heading)
            Text("课表中的当前 Section 优先；没有课表时使用手动选择。").font(Aurora.TypeStyle.caption).foregroundStyle(Aurora.Colors.secondary)
            ScrollView { VStack(alignment: .leading, spacing: Aurora.Space.small) { Button("收件箱 · 只保存，不发送") { model.chooseSection(nil); targetPicker = false }.auroraButton(); ForEach((model.catalog.sections ?? []).filter { section in model.catalog.courses.contains { $0.id == section.courseID && $0.archived != true } }) { section in Button { model.chooseSection(section.id); targetPicker = false } label: { Text("\(model.catalog.courses.first { $0.id == section.courseID }?.name ?? "") → \(section.name)").frame(maxWidth: .infinity, alignment: .leading).padding(Aurora.Space.inset) }.buttonStyle(PressableStyle(row: true)).background(Aurora.Colors.white.opacity(Aurora.Alpha.faint), in: RoundedRectangle(cornerRadius: Aurora.Space.rowRadius)) } } }
            HStack { Button("管理课程与 Section") { targetPicker = false; page = .courses }.auroraButton(); Spacer(); Button("完成") { targetPicker = false }.auroraButton() }
        }.padding(Aurora.Space.page).frame(width: Aurora.Space.editor, height: Aurora.Space.editor).preferredColorScheme(.dark)
    }
    @ViewBuilder private var photoPreview: some View {
        if let photo = model.records.first(where: { $0.id == preview }) {
            VStack(spacing: Aurora.Space.gap) {
                HStack { Text(model.catalog.context(for: photo.sessionID)?.courseName ?? "收件箱").font(Aurora.TypeStyle.heading); Spacer(); Button("关闭") { preview = nil }.keyboardShortcut(.space, modifiers: []) }
                if let url = model.imageURL(photo) { PreviewImage(url: url).frame(maxWidth: .infinity, maxHeight: .infinity) }
                HStack { Button("上一张") { navigate(-1) }.keyboardShortcut(.leftArrow, modifiers: []); Button("下一张") { navigate(1) }.keyboardShortcut(.rightArrow, modifiers: []); Spacer(); Text(model.status(photo)).font(Aurora.TypeStyle.caption).foregroundStyle(Aurora.Colors.secondary); if model.stageOf(photo) == .failed { Button("重发") { model.sendSinglePhotoToAI(photo) } }; if model.stageOf(photo) == .uncertain { Button("确认已发送") { model.resolveCurrent(sent: true) }; Button("确认未发送，重排") { model.resolveCurrent(sent: false) } }; Menu("管理照片") {
                    if model.stageOf(photo) == .queued || model.stageOf(photo) == nil { Button("仅保存，移出发送队列") { model.holdPhoto(photo) } }
                    if model.stageOf(photo) == .held || model.stageOf(photo) == nil { Button("只发送这一张") { model.sendSinglePhotoToAI(photo) } }
                    Button("导出原图") { model.selectedPhotoIDs = [photo.id]; model.batchExportSelected() }
                    Menu("移动到 Section") { ForEach(model.catalog.sections ?? []) { section in Button(section.name) { model.assignPhotos([photo.id], to: section.id, send: false); preview = nil } } }
                    Button("删除 Mac 原图", role: .destructive) { deletingPhoto = true }
                } }
            }.padding(Aurora.Space.page).frame(width: Aurora.Space.preview, height: Aurora.Space.previewHeight).preferredColorScheme(.dark)
                .confirmationDialog("删除 Mac 中的这张原图？", isPresented: $deletingPhoto) {
                    Button("删除 Mac 原图", role: .destructive) { model.selectedPhotoIDs = [photo.id]; if model.batchDeleteSelected() { preview = nil } }
                } message: { Text("这会删除 Mac 归档；手机上的照片保留。") }
        }
    }
    private func navigate(_ delta: Int) { guard let i = model.records.firstIndex(where: { $0.id == preview }), model.records.indices.contains(i + delta) else { return }; preview = model.records[i + delta].id; model.selected = preview }
    private func bannerView(_ banner: AppAlertBanner) -> some View {
        HStack(spacing: Aurora.Space.inset) { Image(systemName: banner.style.icon).foregroundStyle(banner.style.color); VStack(alignment: .leading, spacing: Aurora.Space.tiny) { Text(banner.title).font(Aurora.TypeStyle.caption.weight(.semibold)); Text(banner.message).font(Aurora.TypeStyle.micro).foregroundStyle(Aurora.Colors.secondary).lineLimit(2) }; Spacer(); if let action = banner.actionTitle { Button(action) { model.performBannerAction() }.buttonStyle(PressableStyle(inset: Aurora.Space.tiny)) }; Button { model.dismissAlert() } label: { Image(systemName: "xmark").frame(width: 28, height: 28) }.buttonStyle(PressableStyle(row: true)) }.padding(Aurora.Space.inset).background(Aurora.Colors.white.opacity(Aurora.Alpha.hover), in: RoundedRectangle(cornerRadius: Aurora.Space.rowRadius))
    }
}
private struct PreviewImage: View {
    var url: URL
    @State private var image: CGImage?
    var body: some View { Group { if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() } else { ProgressView() } }.task(id: url) { image = await ThumbnailLoader.shared.load(url, pixels: 1600) }.onDisappear { image = nil } }
}
