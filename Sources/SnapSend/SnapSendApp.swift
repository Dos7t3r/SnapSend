import SwiftUI
import AppKit
@preconcurrency import ApplicationServices
import Network
import SnapSendCore
import UniformTypeIdentifiers
import ImageIO

@main
struct SnapSendApp: App {
    @StateObject private var model = WorkspaceModel()

    var body: some Scene {
        WindowGroup("SnapSend", id: "workspace") {
            WorkspaceView(model: model)
                .frame(minWidth: 960, minHeight: 640)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.disconnect(keepStatus: false, userInitiated: true)
                }
        }.windowStyle(.hiddenTitleBar).defaultSize(width: 1080, height: 720)
        MenuBarExtra { MenuBarPanel(model: model) } label: { Image(systemName: model.menuSymbol).renderingMode(.original).foregroundStyle(model.menuColor) }.menuBarExtraStyle(.window)
    }
}

// MARK: - Banner and Alert Models

enum AlertStyle: Equatable {
    case info, warning, error, success

    var color: Color {
        switch self {
        case .info: return Aurora.Colors.blue
        case .warning: return Aurora.Colors.phone
        case .error: return Aurora.Colors.error
        case .success: return Aurora.Colors.success
        }
    }

    var icon: String {
        switch self {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .success: return "checkmark.circle.fill"
        }
    }
}

struct AppAlertBanner: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let style: AlertStyle
    let actionTitle: String?

    static func == (lhs: AppAlertBanner, rhs: AppAlertBanner) -> Bool {
        lhs.title == rhs.title && lhs.message == rhs.message && lhs.style == rhs.style
    }
}

// MARK: - WorkspaceModel

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var records: [PhotoRecord] = []
    @Published var selected: UUID?
    @Published var connectionStatus = "USB 尚未连接"
    @Published var notice = "欢迎使用 SnapSend。手机插线后将自动建立连接。"
    @Published var axReport = "尚未检查 ChatGPT"
    @Published var targetBundle = "com.openai.chat"
    @Published var port = "27183"
    @Published var usbMode = UserDefaults.standard.string(forKey: "SnapSendUSBMode") == "pad" ? "pad" : "phone" {
        didSet { UserDefaults.standard.set(usbMode, forKey: "SnapSendUSBMode") }
    }
    @Published var pairingCode = ""
    @Published var pairingRequired = false
    @Published var catalog = CourseCatalog()
    @Published var selectedLesson: UUID?
    @Published var autoReconnect: Bool = true {
        didSet { UserDefaults.standard.set(autoReconnect, forKey: "SnapSendAutoReconnect") }
    }
    @Published var usbDevices: [String] = []
    @Published var usbDeviceID = ""
    @Published var findingUSB = false
    func findUSBDevices() {
        guard !findingUSB else { return }; findingUSB = true
        Task {
            defer { findingUSB = false }
            do {
                usbDevices = try await Task.detached(priority: .utility) { try USBDevices.list() }.value
                if usbDevices.count == 1 { usbDeviceID = usbDevices[0] }
                else if !usbDevices.contains(usbDeviceID) { usbDeviceID = "" }
            } catch { notice = "无法读取 USB 设备，请确认数据线与信任状态。" }
        }
    }
    @Published var deliveryTarget = "chrome"
    @Published var autoSend = false
    private var manualDeliveryIDs = Set<UUID>()
    private func permitsDelivery(_ id: UUID) -> Bool { autoSend || manualDeliveryIDs.contains(id) }
    @Published var deliveryReport = "尚未绑定聊天"
    private var deliveryByID: [UUID: DeliveryEntry] = [:]
    @Published var deliveries: [DeliveryEntry] = [] {
        didSet { deliveryByID = Dictionary(deliveries.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest }) }
    }
    @Published var boundLesson: UUID?
    @Published var boundChat = ""
    @Published var browserConnected = false
    @Published var browserPageStatus = ""
    private var targetBoundaryTask: Task<Void, Never>?
    @Published var lastReceivedID: UUID?
    private var browserFocusRequested = false
    @Published var nativeBusy = false
    @Published var alertBanner: AppAlertBanner? = nil
    @Published var showingNewCourseAlert = false
    @Published var showingRenameAlert = false

    // Multi-Selection & Batch Actions
    @Published var isSelectMode = false
    @Published var selectedPhotoIDs: Set<UUID> = []

    // Prompt Customization & Automation
    @Published var classStartPrompt: String = {
        UserDefaults.standard.string(forKey: "SnapSendClassStartPrompt") ??
        "这是我的课堂图片记录。我会持续只发送照片，请按顺序理解其中的内容；每次只简短回复‘已记录’，不要展开讲解。等我说‘下课总结’时，再整理本节课知识点、关键推导、易错点和复习建议。无法看清的内容请标注，不要猜测。"
    }() {
        didSet { UserDefaults.standard.set(classStartPrompt, forKey: "SnapSendClassStartPrompt") }
    }

    @Published var classSummaryPrompt: String = {
        UserDefaults.standard.string(forKey: "SnapSendClassSummaryPrompt") ??
        "下课总结。请基于本节课当前所有图片与对话，按授课顺序整理复习笔记：知识结构、重要定义、公式及适用条件、关键例题步骤、易错点，以及 5 道自测题和参考答案。看不清或上下文缺失的地方请明确标记，不要猜测。"
    }() {
        didSet { UserDefaults.standard.set(classSummaryPrompt, forKey: "SnapSendClassSummaryPrompt") }
    }

    @Published var autoSendPromptOnStartLesson: Bool = {
        if UserDefaults.standard.object(forKey: "SnapSendAutoSendPromptOnStart") != nil {
            return UserDefaults.standard.bool(forKey: "SnapSendAutoSendPromptOnStart")
        }
        return true
    }() {
        didSet { UserDefaults.standard.set(autoSendPromptOnStartLesson, forKey: "SnapSendAutoSendPromptOnStart") }
    }

    @Published var pendingPromptToSend: String? = nil
    private var pendingPromptID = UUID()
    private var pendingPromptLesson: UUID?
    private var pendingPromptIsSummary = false
    private var promptInFlight: UUID?
    private var promptTimeout: Task<Void, Never>?

    private var bannerAction: (() -> Void)?
    private var userRequestedDisconnect = false
    private var autoReconnectTask: Task<Void, Never>?
    private var retryAttempt = 0
    private var browserPresenceTask: Task<Void, Never>?
    private var trusted: [String: String] = [:]
    private var pairingVaultReady = false
    private var pairingLoadBusy = false
    private let macID: UUID = {
        let defaults = UserDefaults.standard
        if let value = defaults.string(forKey: "SnapSendMacID"), let id = UUID(uuidString: value) { return id }
        let id = UUID(); defaults.set(id.uuidString, forKey: "SnapSendMacID"); return id
    }()
    private var store: PhotoStore?
    private var connection: NWConnection?
    private var decoder = WireDecoder()
    private var bridge: Process?
    private var handshakeTimeout: Task<Void, Never>?
    private var bridgeStartup: Task<Void, Never>?
    private var authenticated = false
    private var nativeWindow = ""
    private var boundDestination = ""
    private var ledger: DeliveryLedger?
    private let browserBridge = BrowserBridge()
    private var browserLastSeen = Date.distantPast
    private var browserTab: Int?
    private var deliveryTimeout: Task<Void, Never>?
    private var nativeTask: Task<Void, Never>?

    init(preview: Bool = false) {
        // Offline rendering mode never opens archives, a USB connection or the browser bridge.
        if preview { autoReconnect = false; return }
        if UserDefaults.standard.object(forKey: "SnapSendAutoReconnect") != nil {
            autoReconnect = UserDefaults.standard.bool(forKey: "SnapSendAutoReconnect")
        }
        do {
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
            store = try PhotoStore(directory: base.appendingPathComponent("SnapSend/Prototype"))
            ledger = try DeliveryLedger(directory: store!.directory)
            records = store!.records
            // Repair an interrupted move: archived photo metadata is authoritative.
            let archivedLessons = Dictionary(records.compactMap { photo in photo.sessionID.map { (photo.id, $0) } }, uniquingKeysWith: { first, _ in first })
            for entry in ledger!.entries {
                if let lesson = archivedLessons[entry.id], lesson != entry.lessonID {
                    try ledger!.reassign(ids: [entry.id], lessonID: lesson)
                }
            }
            refreshDeliveries()
            catalog = store!.catalog
            selectedLesson = catalog.activeLessonID ?? catalog.lessons.last?.id
            resolveTarget()
        } catch {
            showAlert(title: "归档无法打开", message: error.localizedDescription, style: .error)
        }
        browserBridge.command = { [weak self] in self?.browserCommand($0) ?? ["ok": false] }
        browserBridge.failure = { [weak self] in
            self?.deliveryReport = $0
            self?.showAlert(title: "浏览器桥接异常", message: $0, style: .warning)
        }
        do {
            try browserBridge.start()
        } catch {
            deliveryReport = "浏览器桥接无法启动：\(error.localizedDescription)"
            showAlert(title: "桥接端口占用", message: "端口可能被其他进程占用，请关闭多余程序后重启。", style: .error)
        }

        loadPairings()
    }

    private func loadPairings() {
        guard !pairingLoadBusy else { return }
        pairingLoadBusy = true; connectionStatus = "正在读取设备配对信息…"
        Task { [weak self] in
            do {
                let pairings = try await Task.detached(priority: .utility) { try PairingVault.load() }.value
                guard let self else { return }
                self.trusted = pairings; self.pairingVaultReady = true; self.pairingLoadBusy = false
                self.connectionStatus = "USB 尚未连接"
                if self.autoReconnect { self.connect(isAutoRetry: true) }
            } catch {
                guard let self else { return }; self.pairingLoadBusy = false
                self.connectionStatus = "配对信息尚未读取"
                self.showAlert(title: "设备配对信息待读取", message: "若 macOS 提示钥匙串访问，请在系统提示中处理后重试。原配对记录未删除。", style: .warning, actionTitle: "重试读取") { self.loadPairings() }
            }
        }
    }

    private func matchesTarget(_ lessonID: UUID?) -> Bool {
        guard let section = catalog.section(for: boundLesson) else { return false }
        return catalog.section(for: lessonID)?.id == section.id
    }
    var targetDisplayName: String { targetSection.map { section in (catalog.courses.first { $0.id == section.courseID }?.name ?? "") + " · " + section.name } ?? "" }
    var targetSection: CourseSection? { catalog.targetSection() }
    var inboxPhotos: [PhotoRecord] { records.filter { $0.sessionID == catalog.inboxLessonID } }
    var pendingPhotos: [PhotoRecord] { records.filter { photo in catalog.courses.first(where: { $0.id == catalog.context(for: photo.sessionID)?.lesson.courseID })?.archived != true && stageOf(photo) != .sent && (photo.sessionID == catalog.inboxLessonID || stageOf(photo) == nil || stageOf(photo) == .queued) } }
    var menuColor: Color { deliveries.contains { [.uncertain, .failed].contains($0.state) } ? Aurora.Colors.error : deliveries.contains { [.preparing, .submitting].contains($0.state) } ? Aurora.Colors.blue : usbConnected && browserConnected && chatMatchesClass && autoSend ? Aurora.Colors.success : Aurora.Colors.queued }
    var menuSymbol: String { deliveries.contains { [.uncertain, .failed].contains($0.state) } ? "exclamationmark.circle.fill" : deliveries.contains { [.preparing, .submitting].contains($0.state) } ? "paperplane.fill" : usbConnected && browserConnected && chatMatchesClass && autoSend ? "checkmark.circle.fill" : "camera" }
    func updateSection(_ section: CourseSection) {
        do { try store?.updateSection(section); refreshCatalog() }
        catch { showAlert(title: "Section 未保存", message: "检查名称、聊天链接和时间；结束时间须晚于开始时间。", style: .error) }
    }
    func chooseSection(_ id: UUID?) {
        guard promptInFlight == nil, !deliveries.contains(where: { [.preparing, .submitting].contains($0.state) }) else {
            showAlert(title: "正在发送", message: "请等待当前发送完成后切换目标。", style: .warning); return
        }
        do { try store?.selectSection(id); resolveTarget(); selectedLesson = catalog.activeLessonID; sendContext() }
        catch { showAlert(title: "目标未切换", message: error.localizedDescription, style: .error) }
    }
    func renameCourseID(_ id: UUID, name: String) {
        do { try store?.renameCourse(id, name: name); refreshCatalog() } catch { showAlert(title: "名称未保存", message: error.localizedDescription, style: .error) }
    }
    func assignPhotos(_ ids: Set<UUID>, to section: UUID, send: Bool) {
        guard !ids.isEmpty, promptInFlight == nil, !deliveries.contains(where: { [.preparing, .submitting].contains($0.state) || ids.contains($0.id) && $0.state == .uncertain }) else {
            showAlert(title: "请先核对发送状态", message: "正在发送或未确认的照片不能移动，以免重复发送。", style: .warning); return
        }
        chooseSection(section)
        guard targetSection?.id == section, let lesson = catalog.activeLessonID else {
            showAlert(title: "课表目标优先", message: "当前正在上课的 Section 优先于手动选择。请在课后分配这些照片。", style: .warning); return
        }
        selectedPhotoIDs = ids; moveSelectedPhotos(to: lesson)
        if send { selectedPhotoIDs = ids; batchSendSelectedToAI() }
    }
    func resolveTarget(now: Date = Date()) {
        guard let store else { return }
        // In-flight receipts must still match the original chat; switch after completion.
        guard promptInFlight == nil, !deliveries.contains(where: { [.preparing, .submitting].contains($0.state) }) else { return }
        do {
            let oldSection = catalog.section(for: boundLesson)?.id
            _ = try store.routeLesson(now: now); catalog = store.catalog
            let target = catalog.targetSection()
            let sameSectionBinding = oldSection != nil && oldSection == target?.id &&
                ((deliveryTarget == "chrome" && boundDestination == "chrome" && boundChat == target?.chatURL) || (deliveryTarget == "native" && boundDestination == "native" && !boundChat.isEmpty))
            if sameSectionBinding {
                // The date archive is bookkeeping; keep the same Section's live chat and sender.
                boundLesson = catalog.activeLessonID
                if pendingPromptToSend != nil { pendingPromptLesson = boundLesson }
            } else if boundLesson != catalog.activeLessonID || boundChat != (target?.chatURL ?? "") && deliveryTarget == "chrome" {
                autoSend = false; manualDeliveryIDs.removeAll(); browserTab = nil; browserPageStatus = ""; boundLesson = catalog.activeLessonID
                boundChat = target?.chatURL ?? ""; boundDestination = boundChat.isEmpty ? "" : "chrome"
                if oldSection != target?.id { pendingPromptToSend = nil }
                deliveryReport = boundChat.isEmpty ? "选择 Section 并绑定聊天；照片会继续保存。" : "聊天已保存，打开对应 Chrome 页面后可开启发送。"
            }
        } catch { showAlert(title: "归档目标不可用", message: error.localizedDescription, style: .error) }
        targetBoundaryTask?.cancel()
        // One wake at the next schedule boundary or midnight; no per-second polling.
        let cal = Calendar.current, start = cal.startOfDay(for: now)
        var boundaries = [cal.date(byAdding: .day, value: 1, to: start)!]
        for section in catalog.sections ?? [] where section.schedule?.weekday == cal.component(.weekday, from: now) {
            if let schedule = section.schedule { for minute in [schedule.startMinute, schedule.endMinute] { if let date = minute == 1440 ? cal.date(byAdding: .day, value: 1, to: start) : cal.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: start), date > now { boundaries.append(date) } } }
        }
        let wait = max(1, boundaries.min()!.timeIntervalSince(now))
        targetBoundaryTask = Task { [weak self] in do { try await Task.sleep(for: .seconds(wait)) } catch { return }; self?.resolveTarget(); self?.sendContext() }
    }

    #if DEBUG || WORKSPACE_FIXTURES
    func configurePreview(store: PhotoStore, usb: Bool = true, connected: Bool = true, sending: Bool = true) throws {
        self.store = store; ledger = try DeliveryLedger(directory: store.directory)
        refreshDeliveries()
        records = store.records; catalog = store.catalog; selectedLesson = catalog.activeLessonID
        pairingVaultReady = true; authenticated = usb; browserConnected = connected; browserLastSeen = connected ? Date() : .distantPast
        boundLesson = catalog.activeLessonID; boundChat = catalog.targetSection()?.chatURL ?? ""
        boundDestination = boundChat.isEmpty ? "" : "chrome"; browserTab = 7; autoSend = sending
        connectionStatus = usb ? "USB 已连接" : "插线并解锁手机"
    }
    #endif
    var usbConnected: Bool { authenticated }
    var chatMatchesClass: Bool { !boundChat.isEmpty && boundLesson != nil && boundLesson == catalog.activeLessonID && boundDestination == deliveryTarget }

    var activeContext: LessonContext? { catalog.context(for: catalog.activeLessonID) }
    var selectedContext: LessonContext? { catalog.context(for: selectedLesson) }
    var lessonPhotos: [PhotoRecord] { records.filter { $0.sessionID == selectedLesson } }
    var current: PhotoRecord? { records.first { $0.id == selected } }
    func imageURL(_ record: PhotoRecord) -> URL? { store?.url(for: record) }
    func chooseLesson(_ id: UUID) { selectedLesson = id; selected = nil; selectedPhotoIDs.removeAll(); isSelectMode = false }
    func archiveCourse(_ id: UUID, archived: Bool) {
        guard let store else { return }
        let ids = Set(records.filter { catalog.context(for: $0.sessionID)?.lesson.courseID == id }.map(\.id))
        guard !(promptInFlight != nil && activeContext?.lesson.courseID == id), !deliveries.contains(where: { ids.contains($0.id) && [.preparing, .submitting].contains($0.state) }) else {
            showAlert(title: "请等待投递完成", message: "正在发送的课程暂时不能移入回收站。", style: .warning); return
        }
        do {
            if archived, activeContext?.lesson.courseID == id { pauseDelivery() }
            try store.archiveCourse(id, archived: archived)
            refreshCatalog()
            if archived, selectedContext?.lesson.courseID == id { selectedLesson = catalog.lessons.last(where: { lesson in catalog.courses.first(where: { $0.id == lesson.courseID })?.archived != true })?.id; selected = nil }
            showAlert(title: archived ? "课程已移到回收站" : "课程已恢复", message: "所有课堂和原图均保留，可在左侧回收站恢复。", style: .info)
        } catch { showAlert(title: "操作失败", message: error.localizedDescription, style: .error) }
    }
    func renameLesson(_ id: UUID, title: String) {
        do { try store?.renameLesson(id, title: title); refreshCatalog() }
        catch { showAlert(title: "改名失败", message: error.localizedDescription, style: .error) }
    }
    func moveSelectedPhotos(to lessonID: UUID) {
        let ids = selectedPhotoIDs
        guard !ids.isEmpty, !deliveries.contains(where: { ids.contains($0.id) && [.preparing, .submitting].contains($0.state) }) else {
            showAlert(title: "暂时不能移动", message: "请选择照片并等待投递完成。", style: .warning); return
        }
        pauseDelivery()
        do {
            try store?.movePhotos(ids: ids, to: lessonID)
            try ledger?.reassign(ids: ids, lessonID: lessonID)
            refreshCatalog(); refreshDeliveries(); selectedPhotoIDs.removeAll(); selected = nil; isSelectMode = false
            showAlert(title: "照片已移动", message: "Mac 原图和归档已移入目标课堂；投递已暂停，请确认目标课堂的聊天后再开启。手机历史仍按拍摄时的课堂保留。", style: .info)
        } catch { refreshCatalog(); refreshDeliveries(); showAlert(title: "移动未完成", message: error.localizedDescription, style: .error) }
    }
    func exportLesson(_ id: UUID) { selectedPhotoIDs = Set(records.filter { $0.sessionID == id }.map(\.id)); batchExportSelected() }
    func exportCourse(_ id: UUID) { selectedPhotoIDs = Set(records.filter { catalog.context(for: $0.sessionID)?.lesson.courseID == id }.map(\.id)); batchExportSelected() }

    func showAlert(title: String, message: String, style: AlertStyle, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        alertBanner = AppAlertBanner(title: title, message: message, style: style, actionTitle: actionTitle)
        bannerAction = action
    }

    func performBannerAction() {
        bannerAction?()
        bannerAction = nil
        alertBanner = nil
    }

    func dismissAlert() {
        alertBanner = nil
        bannerAction = nil
    }

    func postSystemNotification(title: String, message: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = message
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
    }

    private func refreshCatalog() {
        guard let store else { return }
        catalog = store.catalog; records = store.records
        resolveTarget()
        sendContext()
    }

    func createCourse(_ name: String) {
        guard promptInFlight == nil, !deliveries.contains(where: { [.preparing, .submitting].contains($0.state) }) else {
            showAlert(title: "正在发送", message: "发送完成后可以创建并切换课程。", style: .warning); return
        }
        do {
            guard let store else { return }
            let lesson = try store.createCourse(name: name)
            selectedLesson = lesson.id; selected = nil; refreshCatalog()
            showAlert(title: "课程创建成功", message: "已创建“\(name)”和默认 Section，可修改名称并绑定聊天。", style: .success)
            if autoSendPromptOnStartLesson {
                triggerAutoPromptOnLessonStart()
            }
        } catch {
            showAlert(title: "创建课程失败", message: error.localizedDescription, style: .error)
        }
    }

    func newLesson() {
        guard let context = selectedContext, let store else {
            showAlert(title: "无法开始新课堂", message: "请先在左侧选择一门课程。", style: .warning)
            return
        }
        do {
            let lesson = try store.startLesson(courseID: context.lesson.courseID)
            selectedLesson = lesson.id; selected = nil; refreshCatalog()
            showAlert(title: "新课堂已开启", message: "已开始“\(context.courseName)”的新一节课。", style: .success)
            if autoSendPromptOnStartLesson {
                triggerAutoPromptOnLessonStart()
            }
        } catch {
            showAlert(title: "新建课堂失败", message: error.localizedDescription, style: .error)
        }
    }

    func resumeLesson() {
        do {
            try store?.activateLesson(selectedLesson); refreshCatalog()
            showAlert(title: "当前课堂已切换", message: "手机拍照将自动归档至此节课。", style: .info)
            if autoSendPromptOnStartLesson {
                triggerAutoPromptOnLessonStart()
            }
        } catch {
            showAlert(title: "切换课堂失败", message: error.localizedDescription, style: .error)
        }
    }

    private func triggerAutoPromptOnLessonStart() {
        guard promptInFlight == nil else { return }
        queuePrompt(classStartPrompt, summary: false)
        if chatMatchesClass && deliveryTarget == "chrome" && boundDestination == "chrome" {
            enableDelivery()
        } else {
            deliveryReport = "开课提示词已准备，请先绑定本节课的 Chrome 聊天。"
        }
    }

    private func queuePrompt(_ text: String, summary: Bool) {
        pendingPromptID = UUID()
        pendingPromptLesson = catalog.activeLessonID
        pendingPromptIsSummary = summary
        pendingPromptToSend = text
    }

    func renameCourse(_ name: String) {
        guard let context = selectedContext, let store else { return }
        do {
            try store.renameCourse(context.lesson.courseID, name: name); refreshCatalog()
            showAlert(title: "重命名成功", message: "课程名称已更新为“\(name)”。", style: .success)
        } catch {
            showAlert(title: "改名失败", message: error.localizedDescription, style: .error)
        }
    }

    func finishLesson() {
        manualDeliveryIDs.removeAll(); autoSend = false
        do {
            try store?.activateLesson(nil); refreshCatalog()
            showAlert(title: "课堂已结束", message: "拍照已暂停归档，请在 AI 发送下课总结。", style: .info)
        } catch {
            showAlert(title: "结束课堂失败", message: error.localizedDescription, style: .error)
        }
    }

    private func sendCommand(_ line: String) {
        connection?.send(content: Data((line + "\n").utf8), completion: .contentProcessed { _ in })
    }

    private func sendContext() {
        guard authenticated else { return }
        do {
            let value = try activeContext.map { try JSONEncoder().encode($0).base64EncodedString() } ?? "-"
            sendCommand("CONTEXT \(value)")
        } catch {
            notice = "课堂同步失败：\(error.localizedDescription)"
        }
    }

    func sendStatusToPhone(id: UUID, stage: String, detail: String) {
        guard authenticated else { return }
        let base64 = Data(detail.utf8).base64EncodedString()
        sendCommand("STATUS \(id.uuidString) \(stage) \(base64)")
    }

    func submitPairing() {
        let code = pairingCode.filter { $0.isNumber }
        guard code.count == 6 else {
            showAlert(title: "验证码格式错误", message: "请输入手机上显示的 6 位纯数字验证码。", style: .warning)
            return
        }
        sendCommand("PAIR \(code)")
    }

    func importPhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let raw = try Data(contentsOf: url)
            guard let bitmap = NSBitmapImageRep(data: raw),
                  let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
                showAlert(title: "导入失败", message: "无法解码该图片文件。", style: .error); return
            }
            try receive(jpeg)
            showAlert(title: "照片已导入", message: "照片已成功保存至当前课堂。", style: .success)
        } catch {
            showAlert(title: "导入失败", message: error.localizedDescription, style: .error)
        }
    }

    func receive(_ data: Data, header: WireHeader? = nil) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16000, height <= 16000, width * height <= 100_000_000 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard let store else { throw CocoaError(.fileWriteUnknown) }
        // Duplicate retries keep their original archive. New photos resolve the target on the Mac.
        resolveTarget()
        let busy = promptInFlight != nil || deliveries.contains { [.preparing, .submitting].contains($0.state) }
        let route = try records.first(where: { $0.id == header?.id })?.sessionID ?? store.routeLesson(activate: !busy)
        let item = try store.save(data, id: header?.id ?? UUID(), expectedHash: header?.sha256,
                                  sessionID: route, capturedAt: header?.capturedAt,
                                  fileExtension: CGImageSourceGetType(source) as String? == "public.png" ? "png" : "jpg")
        records = store.records; catalog = store.catalog
        if selectedLesson == nil || selectedLesson == item.sessionID {
            selected = item.id; selectedLesson = item.sessionID
        }
        lastReceivedID = item.id
        notice = "照片已保存到 Mac。"
        let previousDelivery = deliveryByID[item.id]
        sendStatusToPhone(id: item.id, stage: previousDelivery?.state.rawValue ?? "received",
                          detail: previousDelivery?.detail ?? "Mac 已保存并归档")

        if matchesTarget(item.sessionID), chatMatchesClass, let lessonID = item.sessionID {
            try ledger?.enqueue(id: item.id, lessonID: lessonID, destination: deliveryTarget, automatic: autoSend && header?.sendToAI != false)
            refreshDeliveries()
            if let delivery = deliveryByID[item.id] {
                sendStatusToPhone(id: item.id, stage: delivery.state.rawValue, detail: delivery.detail)
            }
            pumpNative()
        }
    }

    // MARK: - USB Self-Healing & Connection

    func selfHealUSB(notifyUser: Bool = true) {
        disconnect(keepStatus: true, userInitiated: false, allowAutoReconnect: false)

        connectionStatus = "连接已重置，请确认数据线和手机已解锁。"
        scheduleAutoReconnect()
        if notifyUser { showAlert(title: "重新连接手机", message: "已停止本应用的桥接，将按退避间隔重试。不会清理其他应用的端口或进程。", style: .info) }
    }

    func connect(isAutoRetry: Bool = false) {
        guard pairingVaultReady else {
            connectionStatus = "正在读取设备配对信息；若有系统提示，请先处理"
            loadPairings(); return
        }
        if !isAutoRetry {
            userRequestedDisconnect = false
            retryAttempt = 0
        }
        autoReconnectTask?.cancel()
        autoReconnectTask = nil

        disconnect(keepStatus: isAutoRetry, userInitiated: false, allowAutoReconnect: false)
        pairingCode = ""; pairingRequired = false
        guard let number = UInt16(port), number > 0, let nwPort = NWEndpoint.Port(rawValue: number) else {
            showAlert(title: "无效端口", message: "请输入有效的本地端口号。", style: .warning); return
        }
        let candidates = ["/opt/homebrew/bin/iproxy", "/usr/local/bin/iproxy"]
        guard let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            connectionStatus = "USB 桥接工具未安装"
            showAlert(title: "未安装 libusbmuxd", message: "请在终端执行 brew install libusbmuxd。", style: .error)
            return
        }

        if usbMode == "pad" && usbDeviceID.isEmpty {
            connectionStatus = "请选择 USB 设备；只插 iPad 时点击查找即可自动选择。"
            findUSBDevices(); return
        }
        let process = USBProxyProcess.make(executable: URL(fileURLWithPath: tool),
            arguments: ["-l", "-s", "127.0.0.1"] + (usbDeviceID.isEmpty ? [] : ["-u", usbDeviceID]) + ["\(number):\(usbMode == "pad" ? 27184 : 27183)"])
        process.terminationHandler = { [weak self, weak process] _ in
            Task { @MainActor in
                guard let self, let process, self.bridge === process else { return }
                self.connectionStatus = "USB 桥接已退出，等待重新连接"
                self.disconnect(keepStatus: true, userInitiated: false, allowAutoReconnect: true)
            }
        }
        do {
            try process.run()
        } catch {
            if !isAutoRetry { showAlert(title: "USB 启动失败", message: error.localizedDescription, style: .error) }
            scheduleAutoReconnect(); return
        }
        bridge = process
        connectionStatus = isAutoRetry ? "正在自动重连 USB 设备…" : "正在启动 USB 桥接…"
        bridgeStartup = Task { [weak self, weak process] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, let process, self.bridge === process, process.isRunning else { return }
            self.openBridgeConnection(nwPort, isAutoRetry: isAutoRetry)
        }
    }

    private func openBridgeConnection(_ nwPort: NWEndpoint.Port, isAutoRetry: Bool) {
        decoder = WireDecoder()
        authenticated = false
        let conn = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
        connection = conn
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            Task { @MainActor in
                guard let self, let conn, self.connection === conn else { return }
                switch state {
                case .ready:
                    let name = Data((Host.current().localizedName ?? "我的 Mac").utf8).base64EncodedString()
                    self.sendCommand("HELLO \(self.macID.uuidString) \(name)")
                    self.read(conn)
                case .failed(let error):
                    let desc = error.localizedDescription
                    if desc.contains("Address already in use") || desc.contains("address in use") {
                        self.connectionStatus = "USB 端口被占用 · 等待重试，可在设置更换端口"
                        self.selfHealUSB(notifyUser: false)
                    } else {
                        self.connectionStatus = "连接失败：\(desc)"
                        self.disconnect(keepStatus: true, userInitiated: false, allowAutoReconnect: true)
                    }
                case .waiting(let error):
                    self.connectionStatus = "等待连接：\(error.localizedDescription)"
                default: break
                }
            }
        }
        conn.start(queue: .main)
        handshakeTimeout = Task { [weak self, weak conn] in
            do { try await Task.sleep(for: .seconds(12)) } catch { return }
            guard let self, let conn, self.connection === conn, !self.authenticated else { return }
            self.connectionStatus = "等待手机就绪…"
            self.disconnect(keepStatus: true, userInitiated: false, allowAutoReconnect: true)
        }
    }

    func disconnect(keepStatus: Bool = false, userInitiated: Bool = false, allowAutoReconnect: Bool = true) {
        if userInitiated {
            userRequestedDisconnect = true
            autoReconnectTask?.cancel()
            autoReconnectTask = nil
        }
        bridgeStartup?.cancel(); bridgeStartup = nil
        handshakeTimeout?.cancel(); handshakeTimeout = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel(); connection = nil
        let oldBridge = bridge; bridge = nil
        oldBridge?.terminationHandler = nil
        if oldBridge?.isRunning == true { oldBridge?.terminate() }
        authenticated = false; pairingRequired = false
        if userInitiated {
            connectionStatus = "USB 尚未连接"
            notice = "已手动断开。点击“连接 iPhone”重新连接。"
        } else if !keepStatus {
            connectionStatus = "USB 尚未连接"
        }
        if allowAutoReconnect && !userInitiated && autoReconnect && !authenticated {
            scheduleAutoReconnect()
        }
    }

    private func scheduleAutoReconnect() {
        guard autoReconnect, !userRequestedDisconnect, !authenticated else { return }
        autoReconnectTask?.cancel()
        let delay = min(60.0, 3.0 * pow(2.0, Double(min(retryAttempt, 5))))
        retryAttempt += 1
        connectionStatus = "USB 未连接 · \(Int(delay)) 秒后重试"
        notice = "拔插数据线或解锁手机后将自动恢复连接。"
        autoReconnectTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.autoReconnect, !self.userRequestedDisconnect, !self.authenticated else { return }
            self.connect(isAutoRetry: true)
        }
    }

    private func read(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self, weak conn] data, _, complete, error in
            Task { @MainActor in
                guard let self, let conn, self.connection === conn else { return }
                do {
                    if let data {
                        for (header, photo) in try self.decoder.append(data) {
                            switch header.kind {
                            case "hello":
                                guard let phone = header.deviceID, let challenge = header.challenge else { throw WireDecoder.WireError.invalidHeader }
                                if let secret = self.trusted[phone.uuidString] {
                                    self.sendCommand("PROVE \(PairingCrypto.proof(secret: secret, challenge: challenge))")
                                } else { self.sendCommand("PAIRING") }
                                continue
                            case "pairing":
                                self.pairingRequired = true
                                self.connectionStatus = "首次连接 · 请输入手机 6 位验证码"
                                self.notice = header.message ?? "配对后会记住设备，之后无需输入验证码。"
                                self.showAlert(title: "需要设备配对", message: "首次连接请在上方输入 iPhone 屏幕上显示的 6 位验证码。", style: .info)
                                self.handshakeTimeout?.cancel()
                                self.handshakeTimeout = Task { [weak self] in
                                    do { try await Task.sleep(for: .seconds(65)) } catch { return }
                                    self?.connectionStatus = "验证码已过期，重新连接中…"
                                    self?.disconnect(keepStatus: true, userInitiated: false)
                                }
                                continue
                            case "paired":
                                guard let phone = header.deviceID, let secret = header.secret, secret.count == 64 else { throw WireDecoder.WireError.invalidHeader }
                                var updated = self.trusted; updated[phone.uuidString] = secret
                                try PairingVault.save(updated); self.trusted = updated
                                self.pairingCode = ""; self.pairingRequired = false
                                continue
                            case "failure":
                                self.notice = header.message ?? "配对失败，重新尝试中…"
                                self.connectionStatus = "连接未完成"
                                self.showAlert(title: "配对失败", message: self.notice, style: .warning)
                                self.disconnect(keepStatus: true, userInitiated: false)
                                return
                            case "ready":
                                self.authenticated = true; self.retryAttempt = 0; self.pairingRequired = false
                                self.handshakeTimeout?.cancel(); self.handshakeTimeout = nil
                                self.autoReconnectTask?.cancel(); self.autoReconnectTask = nil
                                self.connectionStatus = "USB 已连接 · 设备已就绪"
                                self.notice = "照片按当前 Section 自动归档；未选择目标时进入收件箱。"
                                self.sendContext()
                                self.postSystemNotification(title: "SnapSend", message: "iPhone 已连接并完成认证")
                                self.dismissAlert()
                                for entry in self.deliveries where entry.lessonID == self.catalog.activeLessonID {
                                    self.sendStatusToPhone(id: entry.id, stage: entry.state.rawValue, detail: entry.detail)
                                }
                                continue
                            default: break
                            }
                            guard self.authenticated else { throw WireDecoder.WireError.invalidHeader }
                            try self.receive(photo, header: header)
                            let ack = Data("RECEIVED \(header.id.uuidString)\n".utf8)
                            conn.send(content: ack, completion: .contentProcessed { _ in })
                        }
                    }
                    if complete || error != nil {
                        self.connectionStatus = self.authenticated ? "USB 已断开 · 正在自动重连…" : "连接断开"
                        self.disconnect(keepStatus: true, userInitiated: false)
                    } else { self.read(conn) }
                } catch {
                    self.notice = "接收失败：\(error.localizedDescription)"
                    self.connectionStatus = "接收异常"; self.disconnect(keepStatus: true, userInitiated: false)
                }
            }
        }
    }

    // MARK: - Delivery Pipeline

    func copyImage() {
        guard let current, let url = imageURL(current), let image = NSImage(contentsOf: url) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        showAlert(title: "图片已复制", message: "原图已复制到剪贴板。", style: .info)
    }

    func inspectChatGPT() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            axReport = "请在系统设置中授予 SnapSend 辅助功能权限，再检查。"
            showAlert(title: "需要辅助功能权限", message: "请在系统设置 → 隐私与安全性 → 辅助功能中勾选 SnapSend。", style: .warning)
            return
        }
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == targetBundle }) else {
            axReport = "请先打开所选的 AI App。"
            showAlert(title: "应用未启动", message: "未检测到所选 AI App，请先打开应用。", style: .warning)
            return
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var roles: [String: Int] = [:]
        var visited = 0
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 18, visited < 600 else { return }
            visited += 1
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success,
               let role = value as? String { roles[role, default: 0] += 1 }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let items = children as? [AXUIElement] { for item in items { walk(item, depth: depth + 1) } }
        }
        walk(root, depth: 0)
        axReport = "检查了 \(visited) 个控件\n" + roles.sorted { $0.key < $1.key }.map { "\($0.key)：\($0.value)" }.joined(separator: "\n")
    }

    func selectDeliveryTarget(_ target: String) {
        guard ["chrome", "native"].contains(target), !nativeBusy, promptInFlight == nil,
              !deliveries.contains(where: { [.preparing, .submitting].contains($0.state) }) else { return }
        autoSend = false; manualDeliveryIDs.removeAll(); deliveryTarget = target; boundDestination = ""; boundChat = ""; browserTab = nil
        if target == "chrome" { resolveTarget() }
        deliveryReport = target == "chrome" ? "已恢复 Section 的网页聊天，检查扩展连接后开启发送。" : "请打开 AI 专用聊天并绑定当前窗口。"
    }
    var chatDisplayName: String {
        deliveryTarget == "native" ? (chatMatchesClass ? boundChat : "未绑定 AI 窗口") : targetSection?.chatURL.flatMap { URL(string: $0)?.host } ?? "未绑定聊天 · 可以拍照并保存"
    }
    func chooseNativeApplication() {
        guard !nativeBusy, !deliveries.contains(where: { [.preparing, .submitting].contains($0.state) }) else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.prompt = "选择 AI App"
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        targetBundle = id; pauseDelivery(); boundDestination = ""; boundChat = ""
        axReport = "已选择 \(url.deletingPathExtension().lastPathComponent)，打开专用聊天后检查权限并绑定窗口。"
    }
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    func testNativeAccessibility() {
        inspectChatGPT()
    }

    func requestBrowserFocus() {
        guard chatMatchesClass, browserConnected, deliveryTarget == "chrome" else { return }
        browserFocusRequested = true
        deliveryReport = "已请求显示绑定聊天，扩展下次检查时将激活它。"
    }
    func refreshBrowserPresence() {
        let present = Date().timeIntervalSince(browserLastSeen) < 45
        if browserConnected != present { browserConnected = present }
        if autoSend && deliveryTarget == "chrome" && !browserConnected {
            autoSend = false
            deliveryReport = "Chrome 扩展断开，自动发送已暂停。请点击扩展重新连接。"
            showAlert(title: "Chrome 连接断开", message: "扩展心跳中断，自动发送已暂停。", style: .warning)
        }
    }

    func refreshDeliveries() { deliveries = ledger?.entries ?? [] }

    func status(_ photo: PhotoRecord) -> String {
        deliveryByID[photo.id]?.detail ?? photo.status
    }

    func stageOf(_ photo: PhotoRecord) -> DeliveryState? {
        deliveryByID[photo.id]?.state
    }

    func changeDelivery(_ id: UUID, _ state: DeliveryState, _ detail: String) throws {
        try ledger?.transition(id: id, state: state, detail: detail)
        refreshDeliveries()
        sendStatusToPhone(id: id, stage: state.rawValue, detail: detail)
    }

    func pauseDelivery() {
        manualDeliveryIDs.removeAll()
        autoSend = false
        deliveryReport = "自动发送已暂停。"
        showAlert(title: "投递已暂停", message: "已暂停自动投递，新照片仅在 Mac 本地归档。", style: .info)
    }

    func enableDelivery() {
        guard boundDestination == deliveryTarget, boundLesson == catalog.activeLessonID, boundLesson != nil else {
            showAlert(title: "未绑定聊天", message: "请先在 Chrome 打开专用聊天并点击扩展绑定。", style: .warning)
            return
        }
        if deliveryTarget == "chrome", Date().timeIntervalSince(browserLastSeen) > 45 {
            showAlert(title: "浏览器未就绪", message: "Chrome 扩展未连接，请在 Chrome 页面打开扩展图标。", style: .warning)
            return
        }
        guard !deliveries.contains(where: { matchesTarget($0.lessonID) && [.uncertain, .failed].contains($0.state) }) else {
            showAlert(title: "存在待核对照片", message: "请先核对异常照片后再开启自动发送。", style: .warning)
            return
        }
        guard !nativeBusy, !deliveries.contains(where: { [.preparing, .submitting].contains($0.state) }) else {
            showAlert(title: "正在发送", message: "请等当前照片处理完成后再开启自动发送。", style: .info); return
        }
        do {
            let previous = deliveries.filter { $0.state == .queued }.map { $0.id }
            try ledger?.holdQueued(); refreshDeliveries()
            for id in previous { sendStatusToPhone(id: id, stage: "held", detail: "旧照片仅保存，请手动选择发送") }
        }
        catch { showAlert(title: "队列未保存", message: error.localizedDescription, style: .error); return }
        manualDeliveryIDs.removeAll(); autoSend = true
        deliveryReport = "自动发送已开启：仅投递当前课堂新照片。"
        showAlert(title: "自动发送已开启", message: "仅自动投递开启后新收到的课堂照片。旧照片和仅保存照片需要你手动选择发送。", style: .success)
        pumpNative()
    }

    func bindNative() {
        do {
            guard let lesson = catalog.activeLessonID else { throw NativeDelivery.Failure("请先开始一节课。") }
            let app = try NativeDelivery.app(targetBundle)
            nativeWindow = try NativeDelivery.title(app)
            autoSend = false; manualDeliveryIDs.removeAll(); boundLesson = lesson; boundChat = nativeWindow; boundDestination = "native"; deliveryTarget = "native"
            deliveryReport = "已绑定窗口：\(nativeWindow)。"
            showAlert(title: "原生窗口已绑定", message: nativeWindow, style: .success)
        } catch {
            deliveryReport = error.localizedDescription
            showAlert(title: "绑定失败", message: error.localizedDescription, style: .error)
        }
    }

    func attachmentTest() {
        guard !nativeBusy, let photo = current, let url = imageURL(photo), matchesTarget(photo.sessionID), deliveryTarget == "native" else {
            showAlert(title: "测试前准备", message: "请在中间选中一张照片并绑定原生窗口。", style: .warning); return
        }
        nativeBusy = true
        nativeTask = Task {
            defer { nativeBusy = false }
            do {
                try await NativeDelivery.send(url: url, bundle: targetBundle, windowTitle: nativeWindow, submit: false, beforeSubmit: {})
                deliveryReport = "附件测试通过。请在 ChatGPT 中删除测试附件。"
                showAlert(title: "附件测试成功", message: "ChatGPT 输入框已附加测试图片，请删除草稿附件后开启自动发送。", style: .success)
            } catch {
                deliveryReport = error.localizedDescription
                showAlert(title: "附件测试失败", message: error.localizedDescription, style: .error)
            }
        }
    }

    func resolveCurrent(sent: Bool) {
        guard let photo = current, let entry = deliveries.first(where: { $0.id == photo.id }), [.uncertain, .failed].contains(entry.state) else { return }
        do {
            try changeDelivery(photo.id, sent ? .sent : .queued, sent ? "用户已确认 AI 收到" : "用户确认未发送，重新排队")
            browserPageStatus = ""
            deliveryReport = "核对结果已保存。"
            dismissAlert()
            showAlert(title: "状态已更新", message: sent ? "已标记为成功发送。" : "已重新加入待发送队列。", style: .success)
        } catch {
            showAlert(title: "保存失败", message: error.localizedDescription, style: .error)
        }
    }

    private func pumpNative() {
        guard deliveryTarget == "native", !nativeBusy,
              !deliveries.contains(where: { matchesTarget($0.lessonID) && [.uncertain, .failed, .preparing, .submitting].contains($0.state) }),
              let entry = deliveries.first(where: { $0.state == .queued && permitsDelivery($0.id) && matchesTarget($0.lessonID) && $0.destination == "native" }),
              let photo = records.first(where: { $0.id == entry.id }), photo.sessionID == entry.lessonID, let url = imageURL(photo) else { return }
        nativeBusy = true
        nativeTask = Task {
            defer { nativeBusy = false; manualDeliveryIDs.removeAll() }
            do {
                try changeDelivery(entry.id, .preparing, "正在附加图片")
                try await NativeDelivery.send(url: url, bundle: targetBundle, windowTitle: nativeWindow, submit: true, beforePaste: {
                    guard self.permitsDelivery(entry.id), self.matchesTarget(entry.lessonID) else { throw NativeDelivery.Failure("发送已暂停，未继续附图。") }
                }) {
                    guard self.permitsDelivery(entry.id), self.matchesTarget(entry.lessonID) else { throw NativeDelivery.Failure("发送已暂停。") }
                    try self.changeDelivery(entry.id, .submitting, "正在点击发送")
                }
                try changeDelivery(entry.id, .uncertain, "已点击发送；原生客户端回执待核对。")
                autoSend = false
                showAlert(title: "请核对发送结果", message: "原生 App 已点击发送，请确认 AI 是否已收到回复。", style: .warning)
            } catch {
                try? changeDelivery(entry.id, .uncertain, error.localizedDescription)
                autoSend = false
                showAlert(title: "原生投递中断", message: error.localizedDescription, style: .error)
            }
        }
    }

    // MARK: - Browser Command Bridge & Prompt Dispatch

    func browserCommand(_ message: [String: Any]) -> [String: Any] {
        browserLastSeen = Date()
        if !browserConnected { browserConnected = true }
        browserPresenceTask?.cancel()
        browserPresenceTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(46)) } catch { return }
            self?.refreshBrowserPresence()
        }
        let kind = message["kind"] as? String ?? ""

        if kind == "requestFocus" { requestBrowserFocus(); return ["ok": chatMatchesClass] }
        if kind == "restore" {
            guard let tab = message["tab"] as? Int, let url = message["url"] as? String,
                  url == targetSection?.chatURL, url == boundChat, deliveryTarget == "chrome",
                  message["section"] as? String == targetSection?.id.uuidString,
                  promptInFlight == nil, !deliveries.contains(where: { [.preparing, .submitting].contains($0.state) }) else {
                return ["ok": false, "error": "保存的 Section 目标不匹配，或正在发送"]
            }
            browserTab = tab; boundDestination = "chrome"; boundLesson = catalog.activeLessonID
            return ["ok": true]
        }
        if kind == "focusResult" { browserFocusRequested = false; return ["ok": true] }
        if kind == "pageState", message["tab"] as? Int == browserTab, message["url"] as? String == boundChat {
            let detail = message["detail"] as? String ?? "浏览器等待中"
            if browserPageStatus != detail { browserPageStatus = detail }
            return ["ok": true]
        }
        if kind == "status", browserTab == nil, chatMatchesClass, message["url"] as? String == boundChat { browserTab = message["tab"] as? Int }
        if kind == "status" {
            let matching = message["tab"] as? Int == browserTab && message["url"] as? String == boundChat &&
                boundLesson == catalog.activeLessonID && boundDestination == "chrome"
            return ["ok": true, "version": 5, "versionString": SnapSendVersion, "usb": authenticated,
                    "lesson": targetDisplayName, "matching": matching, "focusRequested": browserFocusRequested, "targetURL": deliveryTarget == "chrome" ? boundChat : "", "section": targetSection?.id.uuidString ?? "",
                    "auto": (autoSend || !manualDeliveryIDs.isEmpty) && matching,
                    "continuous": autoSend,
                    "inflight": deliveries.contains { matchesTarget($0.lessonID) && [.preparing, .submitting].contains($0.state) }, "review": deliveries.contains { matchesTarget($0.lessonID) && [.uncertain, .failed].contains($0.state) },
                    "hasPrompt": matching && autoSend && pendingPromptToSend != nil && pendingPromptLesson == catalog.activeLessonID && promptInFlight == nil,
                    "queued": deliveries.filter { matchesTarget($0.lessonID) && $0.destination == "chrome" && $0.state == .queued && permitsDelivery($0.id) }.count,
                    "report": deliveryReport]
        }

        if kind == "promptResult" {
            guard let id = message["id"] as? String, id == promptInFlight?.uuidString,
                  message["tab"] as? Int == browserTab, message["url"] as? String == boundChat else {
                return ["ok": false, "error": "提示词回执与绑定不匹配"]
            }
            promptTimeout?.cancel(); promptInFlight = nil
            if id == pendingPromptID.uuidString { pendingPromptToSend = nil }
            if message["success"] as? Bool == true {
                deliveryReport = "提示词已发送，网页中已确认新消息。"
                showAlert(title: "提示词已发送", message: deliveryReport, style: .success)
            } else {
                autoSend = false
                deliveryReport = "提示词发送待核对：" + (message["error"] as? String ?? "未确认新消息")
                showAlert(title: "请核对提示词", message: deliveryReport + "。请到聊天确认；不会自动重发。", style: .warning)
            }
            return ["ok": true]
        }

        if kind == "enable" || kind == "pause" {
            guard message["tab"] as? Int == browserTab, message["url"] as? String == boundChat, boundDestination == "chrome" else {
                return ["ok": false, "error": "请先绑定当前聊天。"]
            }
            if kind == "enable" { enableDelivery() } else { pauseDelivery() }
            return ["ok": kind == "pause" || autoSend, "error": deliveryReport]
        }

        if kind == "bind" {
            guard let url = message["url"] as? String, ChatURL.isConversation(url),
                  let tab = message["tab"] as? Int, let lesson = catalog.activeLessonID else {
                return ["ok": false, "error": "先在 Mac 选择 Section，并在 Chrome 打开具体的 ChatGPT 对话。"]
            }
            guard promptInFlight == nil, !deliveries.contains(where: { [.preparing, .submitting].contains($0.state) }) else {
                return ["ok": false, "error": "请等待当前照片投递完成后再绑定。"]
            }
            browserPageStatus = ""; autoSend = false; manualDeliveryIDs.removeAll(); boundLesson = lesson; boundChat = url; browserTab = tab; boundDestination = "chrome"; deliveryTarget = "chrome"
            if var section = targetSection { section.chatURL = url; try? store?.updateSection(section); catalog = store?.catalog ?? catalog }
            deliveryReport = "已绑定 ChatGPT 聊天：\(url)"
            showAlert(title: "Chrome 聊天绑定成功", message: "当前课堂已成功绑定至 Chrome 标签页。", style: .success)
            if autoSendPromptOnStartLesson {
                queuePrompt(classStartPrompt, summary: false)
            }
            return ["ok": true, "lesson": targetDisplayName, "chat": url]
        }

        if kind == "poll" {
            guard (autoSend || !manualDeliveryIDs.isEmpty), deliveryTarget == "chrome", message["tab"] as? Int == browserTab,
                  message["url"] as? String == boundChat, boundLesson == catalog.activeLessonID else {
                return ["ok": true, "paused": true, "message": "等待绑定课堂并在 Mac 开启自动发送"]
            }
            guard !deliveries.contains(where: { [.preparing, .submitting, .uncertain, .failed].contains($0.state) && matchesTarget($0.lessonID) }) else {
                return ["ok": true, "paused": true, "message": "正在投递或等待异常核对"]
            }
            guard promptInFlight == nil else { return ["ok": true, "paused": true, "message": "正在发送提示词"] }
            let hasQueuedPhotos = deliveries.contains { $0.state == .queued && permitsDelivery($0.id) && matchesTarget($0.lessonID) && $0.destination == "chrome" }
            if autoSend, let prompt = pendingPromptToSend, pendingPromptLesson == boundLesson,
               !pendingPromptIsSummary || !hasQueuedPhotos {
                let id = pendingPromptID
                promptInFlight = id
                promptTimeout?.cancel()
                promptTimeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(60))
                    guard !Task.isCancelled, let self, self.promptInFlight == id else { return }
                    self.promptInFlight = nil
                    if self.pendingPromptID == id { self.pendingPromptToSend = nil }
                    self.autoSend = false
                    self.deliveryReport = "提示词发送超时，请在聊天核对；不会自动重发。"
                    self.showAlert(title: "提示词待核对", message: self.deliveryReport, style: .warning)
                }
                return ["ok": true, "kind": "prompt", "id": id.uuidString, "text": prompt]
            }
            guard let entry = deliveries.first(where: { $0.state == .queued && permitsDelivery($0.id) && matchesTarget($0.lessonID) && $0.destination == "chrome" }),
                  let photo = records.first(where: { $0.id == entry.id }), let url = imageURL(photo) else { return ["ok": true, "idle": true] }
            guard photo.sessionID == entry.lessonID else {
                autoSend = false; deliveryReport = "照片归档与投递目标不一致，请重新打开 SnapSend 修复后再开启发送。"
                return ["ok": false, "error": deliveryReport]
            }
            do {
                let data = try browserJPEG(url)
                try changeDelivery(entry.id, .preparing, "正在上传至 Chrome")
                deliveryTimeout?.cancel()
                deliveryTimeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(100))
                    guard !Task.isCancelled, let self, let state = self.deliveries.first(where: { $0.id == entry.id })?.state,
                          [.preparing, .submitting].contains(state) else { return }
                    try? self.changeDelivery(entry.id, .uncertain, "浏览器响应超时，请核对。")
                    self.autoSend = false
                    self.showAlert(title: "投递超时", message: "照片上传超时，已自动暂停，请核对。", style: .warning)
                }
                return ["ok": true, "id": entry.id.uuidString, "jpeg": data.base64EncodedString(), "filename": "SnapSend-\(entry.id.uuidString).jpg"]
            } catch {
                autoSend = false; deliveryReport = error.localizedDescription
                showAlert(title: "压缩失败", message: error.localizedDescription, style: .error)
                return ["ok": false, "error": "图片准备失败，请在 Mac 检查照片。"]
            }
        }

        if kind == "result" || kind == "submitting" {
            guard message["tab"] as? Int == browserTab, message["url"] as? String == boundChat,
                  let text = message["id"] as? String, let id = UUID(uuidString: text),
                  let entry = deliveries.first(where: { $0.id == id }), matchesTarget(entry.lessonID) else { return ["ok": false, "error": "投递绑定不匹配"] }
            do {
                if kind == "submitting" {
                    guard permitsDelivery(id), boundLesson == catalog.activeLessonID else { return ["ok": false, "error": "发送已暂停。"] }
                    try changeDelivery(id, .submitting, "附件就绪，正在点击发送")
                } else {
                    let result = message["state"] as? String
                    if result != "sent" { browserPageStatus = message["detail"] as? String ?? "发送未确认，请核对" }
                    let state: DeliveryState = result == "sent" && entry.state == .submitting ? .sent : .uncertain
                    try changeDelivery(id, state, message["detail"] as? String ?? "请核对聊天")
                    deliveryTimeout?.cancel()
                    manualDeliveryIDs.remove(id)
                    if state != .sent {
                        autoSend = false
                        showAlert(title: "投递待核对", message: "已点击发送但未确认消息，请去 ChatGPT 确认。", style: .warning, actionTitle: "去核对") {
                            self.selected = id
                        }
                    } else {
                        deliveryReport = "照片已成功发送至 ChatGPT。"
                        resolveTarget()
                    }
                }
                return ["ok": true]
            } catch { return ["ok": false, "error": "投递状态无法保存。"] }
        }
        return ["ok": true, "message": deliveryReport]
    }

    private func browserJPEG(_ url: URL) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0,
                [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2048,
                 kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        let bitmap = NSBitmapImageRep(cgImage: image)
        for quality in [0.85, 0.65, 0.45, 0.25] {
            if let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]), jpeg.count < 680000 { return jpeg }
        }
        throw NativeDelivery.Failure("图片压缩后仍过大；原图已安全归档。")
    }

    // MARK: - Prompt & Host Helpers

    func resetStartPromptToDefault() {
        classStartPrompt = "这是我的课堂图片记录。我会持续只发送照片，请按顺序理解其中的内容；每次只简短回复‘已记录’，不要展开讲解。等我说‘下课总结’时，再整理本节课知识点、关键推导、易错点和复习建议。无法看清的内容请标注，不要猜测。"
        showAlert(title: "已恢复默认提示词", message: "开课提示词已重置为默认内容。", style: .info)
    }

    func resetSummaryPromptToDefault() {
        classSummaryPrompt = "下课总结。请基于本节课当前所有图片与对话，按授课顺序整理复习笔记：知识结构、重要定义、公式及适用条件、关键例题步骤、易错点，以及 5 道自测题和参考答案。看不清或上下文缺失的地方请明确标记，不要猜测。"
        showAlert(title: "已恢复默认提示词", message: "下课总结提示词已重置为默认内容。", style: .info)
    }

    func sendClassStartPromptNow() { sendPromptNow(classStartPrompt, summary: false) }

    func sendClassSummaryPromptNow() { sendPromptNow(classSummaryPrompt, summary: true) }

    private func sendPromptNow(_ text: String, summary: Bool) {
        guard promptInFlight == nil, pendingPromptToSend == nil || pendingPromptLesson != catalog.activeLessonID else {
            showAlert(title: "已有提示词等待发送", message: "请等待当前提示词完成，避免重复发送。", style: .warning)
            return
        }
        guard chatMatchesClass, deliveryTarget == "chrome", boundDestination == "chrome" else {
            showAlert(title: "请先绑定本节课聊天", message: "打开 Chrome 中本节课的聊天，点击扩展绑定，再发送提示词。", style: .warning)
            return
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showAlert(title: "提示词为空", message: "请在设置中填写提示词。", style: .warning)
            return
        }
        enableDelivery()
        guard autoSend else { return }
        queuePrompt(text, summary: summary)
        showAlert(title: "提示词已排队", message: summary ? "本课排队照片发送完成后，再发送总结提示词。" : "Chrome 将发送提示词；有草稿或 AI 正在回答时会等待。", style: .info)
    }

    func copyClassPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(classStartPrompt, forType: .string)
        showAlert(title: "开课提示词已复制", message: "请在 ChatGPT 专用聊天中粘贴并发送。", style: .success)
    }

    func copySummaryPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(classSummaryPrompt, forType: .string)
        showAlert(title: "下课总结提示词已复制", message: "请在 ChatGPT 专用聊天中粘贴发送以生成复习笔记。", style: .success)
    }

    func openChromeExtensions() {
        if let url = URL(string: "chrome://extensions") {
            NSWorkspace.shared.open(url)
        }
    }

    func copyExtensionPath() {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/chrome-extension")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
        showAlert(title: "扩展路径已复制", message: url.path, style: .info)
    }

    func openExtensionFolder() {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/chrome-extension")
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.path, forType: .string)
        NSWorkspace.shared.open(url)
    }

    func installChromeHost() {
        installBrowserHost()
    }

    func installBrowserHost() {
        do {
            let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let host = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/SnapSendNativeHost")
            let idURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/chrome-extension/extension-id.txt")
            let id = try String(contentsOf: idURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard FileManager.default.isExecutableFile(atPath: host.path), id.count == 32 else { throw CocoaError(.fileReadNoSuchFile) }
            let manifest: [String: Any] = ["name": "com.snapsend.bridge", "description": "SnapSend local photo bridge", "path": host.path,
                "type": "stdio", "allowed_origins": ["chrome-extension://\(id)/"]]
            try JSONSerialization.data(withJSONObject: manifest, options: .prettyPrinted)
                .write(to: directory.appendingPathComponent("com.snapsend.bridge.json"), options: .atomic)
            showAlert(title: "Native 桥接已安装", message: "配置已写入 Chrome，请在扩展管理加载已复制路径的扩展目录。", style: .success)
            openExtensionFolder()
        } catch {
            showAlert(title: "桥接安装失败", message: error.localizedDescription, style: .error)
        }
    }

    func showArchive() {
        guard let store else { return }
        if let photo = lessonPhotos.first { NSWorkspace.shared.open(store.url(for: photo).deletingLastPathComponent()) }
        else { NSWorkspace.shared.open(store.directory) }
    }

    func forgetPairings() {
        try? PairingVault.save([:])
        trusted = [:]
        disconnect(userInitiated: true)
        showAlert(title: "配对记忆已清除", message: "下次插线时将重新显示 6 位数字验证码进行验证。", style: .info)
    }

    // MARK: - Local Storage & Cache Management

    func calculateStorageStats() -> (count: Int, sizeFormatted: String) {
        guard let store else { return (0, "0 KB") }
        let bytes = store.calculateStorageBytes()
        let count = store.records.count
        return (count, ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
    }

    func cleanCache() {
        do {
            let freed = try store?.cleanTemporaryCache() ?? 0
            showAlert(title: "缓存清理完成", message: "已安全释放 \(ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)) 临时投递缓存。", style: .success)
        } catch {
            showAlert(title: "清理失败", message: error.localizedDescription, style: .error)
        }
    }

    func resetQueue() {
        do {
            try ledger?.resetQueue()
            manualDeliveryIDs.removeAll(); autoSend = false
            refreshDeliveries()
            showAlert(title: "投递队列已重置", message: "所有异常或卡滞条目已清除，已成功的历史记录已妥善保留。", style: .success)
        } catch {
            showAlert(title: "重置队列失败", message: error.localizedDescription, style: .error)
        }
    }

    // MARK: - Single Photo Send to AI & Batch Operations

    func sendSinglePhotoToAI(_ photo: PhotoRecord) {
        guard !nativeBusy, !deliveries.contains(where: { [.preparing, .submitting].contains($0.state) }) else {
            showAlert(title: "正在投递", message: "请等当前图片完成后再选择单张发送。", style: .info); return
        }
        guard let lessonID = photo.sessionID else {
            showAlert(title: "无法发送", message: "该照片未关联任何课堂。", style: .warning)
            return
        }
        guard chatMatchesClass, !boundChat.isEmpty else {
            showAlert(title: "未绑定 AI 聊天", message: "请先绑定当前课堂的 AI 对话。", style: .warning)
            return
        }
        guard matchesTarget(lessonID) else {
            showAlert(title: "照片属于其他课堂", message: "请先打开照片所属课堂并绑定它的聊天。", style: .warning)
            return
        }
        do {
            try ledger?.forceEnqueue(id: photo.id, lessonID: lessonID, destination: deliveryTarget)
            refreshDeliveries()
            sendStatusToPhone(id: photo.id, stage: "queued", detail: "已单独加入投递队列")
            autoSend = false; manualDeliveryIDs = [photo.id]
            if deliveryTarget == "native" { pumpNative() }
            showAlert(title: "已加入投递队列", message: "该照片已单张加入队列，即将投递至 AI。", style: .success)
        } catch {
            showAlert(title: "发送失败", message: error.localizedDescription, style: .error)
        }
    }

    func holdPhoto(_ photo: PhotoRecord) {
        do {
            guard let lesson = photo.sessionID else { return }
            if stageOf(photo) == nil { try ledger?.enqueue(id: photo.id, lessonID: lesson, destination: deliveryTarget, automatic: false) }
            else { try ledger?.transition(id: photo.id, state: .held, detail: "仅保存，不自动发送") }
            manualDeliveryIDs.remove(photo.id); refreshDeliveries()
            sendStatusToPhone(id: photo.id, stage: "held", detail: "仅保存，不自动发送")
        } catch { showAlert(title: "无法移出队列", message: "图片可能已开始上传，请先暂停投递并在 AI 核对。", style: .warning) }
    }

    func toggleSelectMode() {
        isSelectMode.toggle()
        if !isSelectMode {
            selectedPhotoIDs.removeAll()
        }
    }

    func selectAllPhotos() {
        let ids = lessonPhotos.map { $0.id }
        selectedPhotoIDs = Set(ids)
    }

    func deselectAllPhotos() {
        selectedPhotoIDs.removeAll()
    }

    func togglePhotoSelection(_ id: UUID) {
        if selectedPhotoIDs.contains(id) {
            selectedPhotoIDs.remove(id)
        } else {
            selectedPhotoIDs.insert(id)
        }
    }

    func batchSendSelectedToAI() {
        guard !selectedPhotoIDs.isEmpty else { return }
        guard chatMatchesClass, !boundChat.isEmpty else {
            showAlert(title: "未绑定 AI 聊天", message: "请先绑定当前课堂的 AI 对话。", style: .warning)
            return
        }
        guard records.filter({ selectedPhotoIDs.contains($0.id) }).allSatisfy({ $0.sessionID == boundLesson }),
              !nativeBusy, !deliveries.contains(where: { [.preparing, .submitting].contains($0.state) }) else {
            showAlert(title: "无法批量排队", message: "请选择当前课堂照片，并等待正在发送的照片完成。", style: .warning)
            return
        }
        let count = selectedPhotoIDs.count
        do {
            for id in selectedPhotoIDs {
                if let photo = records.first(where: { $0.id == id }), let lessonID = photo.sessionID {
                    try ledger?.forceEnqueue(id: id, lessonID: lessonID, destination: deliveryTarget)
                    sendStatusToPhone(id: id, stage: "queued", detail: "已批量加入投递队列")
                }
            }
            refreshDeliveries()
            autoSend = false; manualDeliveryIDs = selectedPhotoIDs
            if deliveryTarget == "native" { pumpNative() }
            showAlert(title: "批量发送已启动", message: "已将 \(count) 张选中的照片加入投递队列。", style: .success)
            isSelectMode = false
            selectedPhotoIDs.removeAll()
        } catch {
            showAlert(title: "批量发送失败", message: error.localizedDescription, style: .error)
        }
    }

    func batchDeleteSelected() {
        guard !selectedPhotoIDs.isEmpty else { return }
        guard !nativeBusy, !deliveries.contains(where: { [.preparing, .submitting].contains($0.state) }) else {
            showAlert(title: "照片正在发送", message: "请等待投递完成后再删除。", style: .warning)
            return
        }
        let ids = selectedPhotoIDs
        do {
            try store?.delete(ids: ids)
            try ledger?.remove(ids: ids)
            refreshCatalog()
            refreshDeliveries()
            if let sel = selected, ids.contains(sel) {
                selected = nil
            }
            selectedPhotoIDs.removeAll()
            isSelectMode = false
            showAlert(title: "已批量删除", message: "成功删除了 \(ids.count) 张照片及其本地原图文件。", style: .info)
        } catch {
            refreshCatalog(); refreshDeliveries()
            showAlert(title: "批量删除未完成", message: error.localizedDescription, style: .error)
        }
    }

    func batchExportSelected() {
        guard !selectedPhotoIDs.isEmpty, let store else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "导出至此文件夹"
        guard panel.runModal() == .OK, let targetFolder = panel.url else { return }
        var successCount = 0
        for id in selectedPhotoIDs {
            if let photo = records.first(where: { $0.id == id }) {
                let sourceURL = store.url(for: photo)
                let destURL = targetFolder.appendingPathComponent("SnapSend-\(photo.id.uuidString).\(sourceURL.pathExtension)")
                if (try? FileManager.default.copyItem(at: sourceURL, to: destURL)) != nil {
                    successCount += 1
                }
            }
        }
        showAlert(title: successCount == selectedPhotoIDs.count ? "导出完成" : "部分照片未导出", message: "已导出 \(successCount) / \(selectedPhotoIDs.count) 张。已有同名文件不会覆盖；未导出的原图仍保留。", style: successCount == selectedPhotoIDs.count ? .success : .warning)
        isSelectMode = false
        selectedPhotoIDs.removeAll()
    }

    func batchMarkDelivered() {
        guard !selectedPhotoIDs.isEmpty else { return }
        for id in selectedPhotoIDs {
            try? changeDelivery(id, .sent, "批量标记为已由 AI 接收")
        }
        refreshDeliveries()
        showAlert(title: "批量标记完成", message: "已将 \(selectedPhotoIDs.count) 张照片标记为 AI 已接收状态。", style: .success)
        isSelectMode = false
        selectedPhotoIDs.removeAll()
    }
}

// MARK: - Redesigned Liquid Glass Workspace UI
