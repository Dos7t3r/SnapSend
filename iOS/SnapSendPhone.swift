import SwiftUI
import UIKit
import Network
import CryptoKit
import Security
import ImageIO

@main
struct SnapSendPhoneApp: App {
    @StateObject private var model = PhoneModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            PhoneView(model: model)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in Task { await ThumbnailLoader.shared.clear() } }
                .onChange(of: phase) { _, phase in
                if phase == .active { model.startServer() }
                else if phase == .background { model.stopServer() }
            }
        }
    }
}

@MainActor
final class PhoneModel: ObservableObject {
    @Published var photos: [PhonePhoto] = []
    @Published var status = "正在准备 USB 服务…"
    @Published var errorMessage: String?
    @Published var connected = false
    @Published var sendingID: UUID?
    @Published var pairingCode: String?
    @Published var peerName = ""
    @Published var activeContext: LessonContext?
    private var trusted: [String: String] = [:]
    private var peerID: UUID?
    private var proofChallenge = ""
    private var pairChallenge: PairingChallenge?
    private var contextSynced = false
    private var failedAttempts = 0
    private var blockedUntil = Date.distantPast
    let deviceID: UUID
    private var library: PhoneLibrary?
    private var listener: NWListener?
    private var connection: NWConnection?
    private var commandBuffer = Data()
    private var authenticated = false
    private var deadline: Task<Void, Never>?
    var pendingCount: Int { photos.filter { !$0.receivedByMac }.count }

    init(preview: Bool = false) {
        if preview { deviceID = UUID(); status = "USB 服务已就绪 · 等待 Mac 连接"; return }
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "SnapSendPhoneID"), let id = UUID(uuidString: saved) { deviceID = id }
        else { deviceID = UUID(); defaults.set(deviceID.uuidString, forKey: "SnapSendPhoneID") }
        if let value = defaults.data(forKey: "SnapSendLastClass") {
            activeContext = try? JSONDecoder().decode(LessonContext.self, from: value)
        }
        do { trusted = try PairingVault.load() }
        catch { errorMessage = "设备记忆读取失败：\(error.localizedDescription)" }
        do {
            let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("PendingPhotos")
            library = try PhoneLibrary(directory: folder)
            refresh()
        } catch { errorMessage = "无法读取照片历史：\(error.localizedDescription)" }
        startServer()
    }
    private func refresh() { photos = library?.photos ?? [] }
    func save(_ image: UIImage, context: LessonContext?, quality: Double = 0.9) {
        guard let context else { errorMessage = "请先在 Mac 开始一节课"; return }
        guard let bytes = image.jpegData(compressionQuality: quality), let library else { errorMessage = "照片编码或队列初始化失败"; return }
        do {
            try library.save(bytes, context: context); refresh(); errorMessage = nil
            if authenticated { sendNext() }
        } catch { errorMessage = "保存失败：\(error.localizedDescription)" }
    }
    func startServer() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            // usbmux reaches the phone's loopback service; do not expose it to Wi-Fi.
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 27183)
            let server = try NWListener(using: parameters)
            listener = server
            server.stateUpdateHandler = { [weak self, weak server] state in
                Task { @MainActor in
                    guard let self, let server, self.listener === server else { return }
                    switch state {
                    case .ready: self.status = "USB 服务已就绪 · 等待 Mac 连接"
                    case .failed(let error): self.errorMessage = "USB 服务启动失败：\(error.localizedDescription)"; self.stopServer()
                    default: break
                    }
                }
            }
            server.newConnectionHandler = { [weak self] incoming in
                Task { @MainActor in self?.accept(incoming) }
            }
            server.start(queue: .main)
        } catch { errorMessage = "USB 服务启动失败：\(error.localizedDescription)" }
    }
    func stopServer() {
        listener?.stateUpdateHandler = nil; listener?.cancel(); listener = nil
        closeConnection()
        status = "USB 服务已停止 · 回到前台后恢复"
    }
    private func accept(_ incoming: NWConnection) {
        guard connection == nil else { incoming.cancel(); return }
        connection = incoming; commandBuffer = Data(); authenticated = false
        contextSynced = false; peerID = nil
        incoming.stateUpdateHandler = { [weak self, weak incoming] state in
            Task { @MainActor in
                guard let self, let incoming, self.connection === incoming else { return }
                switch state {
                case .ready: self.read(incoming)
                case .failed, .cancelled: self.closeConnection()
                default: break
                }
            }
        }
        incoming.start(queue: .main)
        armDeadline(seconds: 12, message: "连接握手超时")
    }
    private func closeConnection() {
        deadline?.cancel(); deadline = nil
        connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil
        authenticated = false; connected = false; sendingID = nil; commandBuffer = Data()
        pairingCode = nil; pairChallenge = nil; peerID = nil; contextSynced = false
        UIApplication.shared.isIdleTimerDisabled = false
        if listener != nil { status = "USB 已断开 · 照片保留，等待重新连接" }
    }
    private func armDeadline(seconds: Double, message: String) {
        deadline?.cancel()
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self else { return }
            self.errorMessage = message; self.closeConnection()
        }
    }
    private func read(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak conn] data, _, complete, error in
            Task { @MainActor in
                guard let self, let conn, self.connection === conn else { return }
                if let data {
                    self.commandBuffer.append(data)
                    guard self.commandBuffer.count <= 8192 else { self.closeConnection(); return }
                    while let newline = self.commandBuffer.firstIndex(of: 10) {
                        let line = String(data: self.commandBuffer.prefix(upTo: newline), encoding: .utf8) ?? ""
                        self.commandBuffer = Data(self.commandBuffer.suffix(from: self.commandBuffer.index(after: newline)))
                        self.handle(line, connection: conn)
                        guard self.connection === conn else { return }
                    }
                }
                if complete || error != nil { self.closeConnection() }
                else { self.read(conn) }
            }
        }
    }
    private func sendControl(_ kind: String, message: String? = nil, secret: String? = nil) {
        guard let conn = connection else { return }
        do {
            var header = WireHeader(kind: kind)
            header.deviceID = deviceID; header.message = message; header.secret = secret
            if kind == "hello" { header.challenge = proofChallenge }
            let frame = try WireEncoder.encode(header)
            conn.send(content: frame, completion: .contentProcessed { _ in })
        } catch { errorMessage = "连接消息编码失败"; closeConnection() }
    }
    private func reject(_ message: String) {
        errorMessage = message
        guard let conn = connection else { return }
        do {
            var header = WireHeader(kind: "failure"); header.message = message
            conn.send(content: try WireEncoder.encode(header), completion: .contentProcessed { [weak self, weak conn] _ in
                Task { @MainActor in
                    guard let self, let conn, self.connection === conn else { return }
                    self.closeConnection()
                }
            })
        } catch { closeConnection() }
    }
    private func beginPairing() {
        guard peerID != nil else { reject("请先连接 Mac"); return }
        guard Date() >= blockedUntil else { reject("验证码尝试过多，请稍后重试"); return }
        if failedAttempts >= 3 { failedAttempts = 0 }
        pairChallenge = PairingChallenge()
        pairingCode = pairChallenge?.code
        status = "首次配对 · 在 Mac 输入下方验证码"
        sendControl("pairing", message: "请输入手机上的 6 位验证码，60 秒内有效。")
        armDeadline(seconds: 60, message: "验证码已过期，重新连接即可获取新验证码")
    }
    private func authorize() {
        authenticated = true; connected = true; errorMessage = nil; pairingCode = nil; pairChallenge = nil
        deadline?.cancel(); deadline = nil
        UIApplication.shared.isIdleTimerDisabled = false
        status = "USB 已连接 · 正在同步课堂"
        sendControl("ready")
        // Wait for Mac's current class before starting transmission.
        armDeadline(seconds: 12, message: "课堂同步超时，请重新连接")
    }
    func forgetPairings() {
        do { try PairingVault.save([:]); trusted = [:]; closeConnection(); status = "已忘记设备 · 下次连接使用新验证码" }
        catch { errorMessage = "无法更新配对记录：\(error.localizedDescription)" }
    }
    func retry(_ photo: PhonePhoto) {
        do { try library?.requeue(photo.id); refresh(); sendNext() }
        catch { errorMessage = "无法重新排队：\(error.localizedDescription)" }
    }
    private func handle(_ line: String, connection conn: NWConnection) {
        if !authenticated {
            if line.hasPrefix("HELLO "), peerID == nil {
                let parts = line.split(separator: " ")
                guard parts.count == 3, let id = UUID(uuidString: String(parts[1])),
                      let data = Data(base64Encoded: String(parts[2])), data.count <= 256,
                      let name = String(data: data, encoding: .utf8) else { reject("连接信息无效"); return }
                peerID = id; peerName = name
                if trusted[id.uuidString] != nil {
                    do { proofChallenge = try PairingCrypto.secret(); sendControl("hello") }
                    catch { reject("无法生成设备验证挑战") }
                } else { beginPairing() }
            } else if line == "PAIRING" { beginPairing() }
            else if line.hasPrefix("PROVE "), let id = peerID, let secret = trusted[id.uuidString], !proofChallenge.isEmpty {
                guard PairingCrypto.matches(String(line.dropFirst(6)), secret: secret, challenge: proofChallenge) else {
                    reject("设备认证失效，请在手机连接设置中忘记设备后重新配对"); return
                }
                authorize()
            } else if line.hasPrefix("PAIR "), let id = peerID, var challenge = pairChallenge {
                let approved = challenge.verify(String(line.dropFirst(5)))
                pairChallenge = challenge
                guard approved else {
                    failedAttempts += 1
                    if challenge.attempts >= 3 || Date() >= challenge.expiresAt || failedAttempts >= 3 {
                        blockedUntil = Date().addingTimeInterval(60)
                        reject("验证码无效或已过期，请一分钟后重新连接")
                    } else {
                        errorMessage = "验证码不正确，请重新输入"
                        sendControl("pairing", message: "验证码不正确，请重试。")
                    }
                    return
                }
                do {
                    let secret = try PairingCrypto.secret()
                    var updated = trusted; updated[id.uuidString] = secret
                    try PairingVault.save(updated); trusted = updated; failedAttempts = 0
                    sendControl("paired", secret: secret); authorize()
                } catch { reject("配对保存失败，请重新连接") }
            } else { reject("连接协议不匹配，请更新 Mac 和手机两端 App") }
        } else if line.hasPrefix("CONTEXT ") {
            let value = String(line.dropFirst(8))
            do {
                if value == "-" {
                    activeContext = nil; UserDefaults.standard.removeObject(forKey: "SnapSendLastClass")
                } else {
                    guard let data = Data(base64Encoded: value), data.count <= 4096 else { reject("课堂数据无效"); return }
                    let context = try JSONDecoder().decode(LessonContext.self, from: data)
                    try library?.updateCourseName(from: context); refresh()
                    activeContext = context
                    UserDefaults.standard.set(data, forKey: "SnapSendLastClass")
                }
                contextSynced = true
                if sendingID == nil { deadline?.cancel(); deadline = nil; sendNext() }
            } catch { reject("课堂同步失败") }
        } else if line.hasPrefix("RECEIVED "), let id = UUID(uuidString: String(line.dropFirst(9))), id == sendingID {
            do {
                try library?.acknowledge(id)
                deadline?.cancel(); deadline = nil; sendingID = nil; UIApplication.shared.isIdleTimerDisabled = false; refresh(); sendNext()
            } catch { errorMessage = "接收状态保存失败：\(error.localizedDescription)"; closeConnection() }
        } else if line.hasPrefix("STATUS ") {
            let parts = line.split(separator: " ", maxSplits: 3)
            if parts.count >= 3, let id = UUID(uuidString: String(parts[1])) {
                let stage = String(parts[2])
                let detail: String
                if parts.count >= 4, let data = Data(base64Encoded: String(parts[3])), let text = String(data: data, encoding: .utf8) {
                    detail = text
                } else { detail = "" }
                try? library?.updateStage(id: id, stage: stage, detail: detail)
                refresh()
            }
        } else { reject("收到不合法的传输确认") }
    }
    private func sendNext() {
        guard authenticated, contextSynced, sendingID == nil, let conn = connection else { return }
        guard let photo = photos.first(where: { !$0.receivedByMac }) else {
            status = activeContext == nil ? "课堂已结束 · 在 Mac 开始下一节课" : "照片已同步 · 可以继续拍照"; return
        }
        do {
            let bytes = try Data(contentsOf: photo.url)
            guard bytes.count <= 40 * 1024 * 1024 else { throw PhoneLibrary.LibraryError.invalidSize }
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            var header = WireHeader(kind: "photo", id: photo.id, byteCount: bytes.count, sha256: hash)
            header.sessionID = photo.context?.lesson.id; header.capturedAt = photo.createdAt
            let frame = try WireEncoder.encode(header, body: bytes)
            sendingID = photo.id; UIApplication.shared.isIdleTimerDisabled = true; status = "正在传输 · 还剩 \(pendingCount) 张"
            armDeadline(seconds: 60, message: "Mac 接收确认超时，照片保留，重新连接即可重试")
            conn.send(content: frame, completion: .contentProcessed { [weak self, weak conn] error in
                Task { @MainActor in
                    guard let self, let conn, self.connection === conn, let error else { return }
                    self.errorMessage = "传输失败：\(error.localizedDescription)"; self.closeConnection()
                }
            })
        } catch { errorMessage = "照片读取失败：\(error.localizedDescription)"; closeConnection() }
    }
}

struct PhoneView: View {
    @ObservedObject var model: PhoneModel
    @State private var camera = false
    @State private var captureContext: LessonContext?
    @State private var gallery: PhotoGallerySelection?
    @State private var screen = "capture"
    @State private var filter = "all"
    @State private var selectedCourse = "all"
    @AppStorage("SnapSendJPEGQuality") private var quality = "清晰"
    @AppStorage("SnapSendAppearance") private var appearance = "system"
    @State private var forget = false
    @State private var help = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var filtered: [PhonePhoto] {
        if screen == "capture" {
            guard let id = model.activeContext?.lesson.id else { return [] }
            return model.photos.filter { $0.context?.lesson.id == id }
        }
        return model.photos.filter { (filter != "pending" || !$0.receivedByMac) && (selectedCourse == "all" || $0.context?.lesson.courseID.uuidString == selectedCourse) }
    }
    private var groups: [UUID?] {
        var result: [UUID?] = []
        for photo in filtered.reversed() {
            let id = photo.context?.lesson.id
            if !result.contains(id) { result.append(id) }
        }
        return result
    }
    private var courses: [LessonContext] {
        var ids = Set<UUID>()
        return model.photos.compactMap(\.context).filter { ids.insert($0.lesson.courseID).inserted }
    }
    var body: some View {
        TabView(selection: $screen) {
            NavigationStack { photoScreen(current: true) }
                .tabItem { Label("课堂", systemImage: "camera.fill") }.tag("capture")
            NavigationStack { photoScreen(current: false) }
                .tabItem { Label("照片", systemImage: "square.stack.3d.up") }.tag("history")
            NavigationStack { settingsScreen }
                .tabItem { Label("设置", systemImage: "slider.horizontal.3") }.tag("settings")
        }.environment(\.locale, Locale(identifier: "zh_CN")).tint(SnapTheme.blue)
            .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
            .fullScreenCover(isPresented: $camera) {
                SystemCamera { image in model.save(image, context: captureContext, quality: quality == "快速" ? 0.6 : 0.9) }
            }
            .fullScreenCover(item: $gallery) { selection in
                LessonPhotoViewer(model: model, photos: selection.photos, initialID: selection.id)
            }
            .sheet(isPresented: $help) {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            SnapMark(size: 72)
                            Text("拍下课堂，留给自己").font(.largeTitle.bold())
                            guideRow("1", "连接 Mac", "用数据线连接，解锁 iPhone 并打开 SnapSend。无需个人热点或校园网。")
                            guideRow("2", "选择这节课", "在 Mac 新建课程或开始新一节课。手机会显示当前课程，照片自动归入这节课。")
                            guideRow("3", "确认一张照片", "点拍照，用系统相机拍摄并确认。先保留原图，再通过 USB 传到 Mac。")
                            guideRow("4", "让 AI 记录", "在 Mac 配置 AI 投递，在 Chrome 专用聊天中绑定。投递不确定时会暂停，请到 Mac 核对。")
                            Text("断线后仍可记录最近课堂，重新连接会续传。App 进入后台时 USB 服务会暂停；传输时请保持打开。").font(.callout).foregroundStyle(.secondary)
                        }.padding(24)
                    }.background(SnapBackdrop()).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { help = false } } }
                }
            }
    }
    private func guideRow(_ number: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number).font(.headline).foregroundStyle(.white).frame(width: 32, height: 32).background(SnapTheme.gradient, in: Circle())
            VStack(alignment: .leading, spacing: 6) { Text(title).font(.headline); Text(detail).font(.callout).foregroundStyle(.secondary) }
        }
    }
    private func photoScreen(current: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 5) { Text(current ? "记录此刻" : "课堂相册").font(.system(size: 34, weight: .bold, design: .rounded)); Text(Date.now.formatted(.dateTime.month().day().weekday().locale(Locale(identifier: "zh_CN")))).font(.subheadline).foregroundStyle(.secondary) }
                    Spacer()
                    Button { help = true } label: { Image(systemName: "questionmark").font(.headline).frame(width: 44, height: 44) }.modifier(SnapGlass()).accessibilityLabel("查看使用引导")
                }
                if let code = model.pairingCode {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("首次连接，验证你的 Mac", systemImage: "lock.shield").font(.headline)
                        Text(code).font(.system(size: 38, weight: .semibold, design: .rounded)).tracking(6)
                        Text("在 Mac 输入这 6 位码 · 60 秒有效\n配对成功后，下次自动连接").font(.callout).foregroundStyle(.secondary)
                    }.padding(22).frame(maxWidth: .infinity, alignment: .leading).modifier(SnapSurface())
                }
                if current { classroomCard }
                else {
                    HStack {
                        Picker("传输状态", selection: $filter) { Text("全部").tag("all"); Text("待传输").tag("pending") }.pickerStyle(.segmented)
                        Menu { Button("全部课程") { selectedCourse = "all" }; ForEach(courses, id: \.lesson.courseID) { context in Button(context.courseName) { selectedCourse = context.lesson.courseID.uuidString } } } label: { Image(systemName: "line.3.horizontal.decrease").padding(10) }.modifier(SnapGlass()).accessibilityLabel("按课程筛选")
                    }
                }
                connectionCard
                if let error = model.errorMessage { Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red).padding(16).modifier(SnapSurface(radius: 18)) }
                HStack { Text(current ? "这节课的照片" : "按课堂整理").font(.headline); Spacer(); Text("\(filtered.count) 张").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary) }
                if filtered.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: current ? "camera.viewfinder" : "square.stack.3d.up").font(.system(size: 46, weight: .light)).foregroundStyle(SnapTheme.gradient)
                        Text(current ? "准备好第一张照片" : "这里会留下你的课堂").font(.headline)
                        Text(current ? (model.activeContext == nil ? "先在 Mac 开始一节课，课程名称会自动显示在这里。" : "确认拍摄后自动保存。连接 Mac 时会自动传输。") : "照片按课程和每次上课时间归档。也可以筛选还未传到 Mac 的照片。")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.padding(28).frame(maxWidth: .infinity).modifier(SnapSurface())
                }
                ForEach(groups, id: \.self) { id in
                    let group = filtered.filter { $0.context?.lesson.id == id }
                    VStack(alignment: .leading, spacing: 14) {
                        if !current {
                            VStack(alignment: .leading, spacing: 4) { Text(group.first?.context?.courseName ?? "早期照片").font(.title3.bold()); if let context = group.first?.context { Text(context.lesson.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) } }
                        }
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                            ForEach(group.reversed()) { photo in
                                Button { gallery = PhotoGallerySelection(photo: photo, photos: group) } label: {
                                    VStack(alignment: .leading, spacing: 9) {
                                        PhotoThumbnail(url: photo.url).frame(height: 150).frame(maxWidth: .infinity).clipped().clipShape(RoundedRectangle(cornerRadius: 17))
                                        HStack { Text(photo.createdAt, style: .time).monospacedDigit(); Spacer(); Image(systemName: photo.statusIcon(sendingID: model.sendingID)) }.font(.caption.weight(.medium)).foregroundStyle(photo.statusColor(sendingID: model.sendingID))
                                        Text(photo.statusText(sendingID: model.sendingID)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                    }.padding(10).modifier(SnapSurface(radius: 22))
                                }.buttonStyle(.plain).accessibilityLabel("\(photo.createdAt.formatted())，\(photo.statusText(sendingID: model.sendingID))，查看大图")
                            }
                        }
                    }
                }
            }.padding(20).padding(.bottom, 12)
        }.background(SnapBackdrop()).toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom) {
                if current {
                    VStack(spacing: 7) {
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            captureContext = model.activeContext; camera = true
                        } label: { Label("拍下这一页", systemImage: "camera.fill").frame(maxWidth: .infinity).padding(.vertical, 3) }.buttonStyle(SnapPrimaryButton())
                            .disabled(model.activeContext == nil || !UIImagePickerController.isSourceTypeAvailable(.camera))
                        Text(model.activeContext == nil ? "在 Mac 开始课堂后即可拍照" : model.connected ? "确认后自动保存并传到 Mac" : "离线也能拍，连接后自动续传").font(.caption).foregroundStyle(.secondary)
                    }.padding(15).modifier(SnapGlass()).padding(.horizontal, 20).padding(.bottom, 10)
                }
            }
    }
    private var classroomCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Label(model.activeContext == nil ? "等待开课" : "当前课堂", systemImage: "book.closed.fill").font(.caption.weight(.semibold)).foregroundStyle(SnapTheme.blue); Spacer(); SnapMark(size: 36) }
            Text(model.activeContext?.courseName ?? "下一节，值得记录").font(.system(size: 27, weight: .bold, design: .rounded))
            if let context = model.activeContext { Text(context.lesson.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.subheadline).foregroundStyle(.secondary) }
            else { Text("在 Mac 选择课程并开始上课").font(.subheadline).foregroundStyle(.secondary) }
            HStack(spacing: 24) {
                metric("已拍摄", value: filtered.count)
                metric("Mac 已保存", value: filtered.filter(\.receivedByMac).count)
                metric("待同步", value: filtered.filter { !$0.receivedByMac }.count)
            }
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).modifier(SnapSurface(radius: 28))
    }
    private func metric(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text("\(value)").font(.system(size: 25, weight: .semibold, design: .rounded)).contentTransition(.numericText()); Text(title).font(.caption2).foregroundStyle(.secondary) }.animation(reduceMotion ? nil : .snappy, value: value)
    }
    private var connectionCard: some View {
        HStack(spacing: 12) {
            Image(systemName: model.connected ? "cable.connector" : "cable.connector.slash").font(.title3).foregroundStyle(model.connected ? SnapTheme.blue : Color.orange).frame(width: 40, height: 40).background(SnapTheme.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) { Text(model.connected ? "已连接 \(model.peerName.isEmpty ? "Mac" : model.peerName)" : "等待 USB 连接").font(.subheadline.bold()); Text(model.connected ? (model.sendingID == nil ? "传输时保持亮屏；空闲时允许自动锁屏" : "正在传输，完成后恢复自动锁屏") : model.status).font(.caption).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
            if model.sendingID != nil { ProgressView().accessibilityLabel("正在传输照片") }
            else { Image(systemName: model.connected ? "checkmark.circle.fill" : "clock").foregroundStyle(model.connected ? SnapTheme.blue : Color.secondary) }
        }.padding(15).modifier(SnapSurface(radius: 20))
    }
    private var settingsScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 14) { SnapMark(size: 64); VStack(alignment: .leading, spacing: 5) { Text("SnapSend").font(.largeTitle.bold()); Text("你的课堂，相片与灵感").font(.callout).foregroundStyle(.secondary) } }
                connectionCard
                VStack(alignment: .leading, spacing: 16) {
                    Label("拍摄与外观", systemImage: "camera.aperture").font(.headline)
                    Picker("图片质量", selection: $quality) { Text("清晰").tag("清晰"); Text("快速").tag("快速") }
                    Text("清晰适合板书和细小文字；快速减少传输文件大小。手机始终保留拍摄图片。").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    Picker("主题", selection: $appearance) { Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark") }
                }.padding(20).modifier(SnapSurface())
                VStack(alignment: .leading, spacing: 16) {
                    Label("本地照片", systemImage: "photo.stack").font(.headline)
                    LabeledContent("已保存", value: "\(model.photos.count) 张")
                    LabeledContent("等待传到 Mac", value: "\(model.pendingCount) 张")
                    Text("传输完成后手机照片仍保留。历史相册中可以查看大图、左右切换和缩放。").font(.caption).foregroundStyle(.secondary)
                }.padding(20).modifier(SnapSurface())
                VStack(alignment: .leading, spacing: 16) {
                    Button { help = true } label: { Label("连接与使用指南", systemImage: "questionmark.circle") }
                    Divider()
                    Button("忘记已配对电脑", role: .destructive) { forget = true }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading).modifier(SnapSurface())
                Text("SnapSend \(SnapSendVersion) · 课堂照片先保存，再传输").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }.padding(20)
        }.background(SnapBackdrop()).navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
            .alert("忘记已配对电脑？", isPresented: $forget) {
                Button("取消", role: .cancel) {}
                Button("忘记设备", role: .destructive) { model.forgetPairings() }
            } message: { Text("照片不会删除，下次连接需要重新验证。") }
    }
}

struct PhotoThumbnail: View {
    let url: URL
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Rectangle().fill(.quaternary).overlay { Image(systemName: "photo") } }
        }.task(id: url) {
            let cg = await ThumbnailLoader.shared.load(url)
            guard !Task.isCancelled else { return }
            image = cg.map { UIImage(cgImage: $0) }
        }.onDisappear { image = nil }
    }
}

struct PhotoGallerySelection: Identifiable {
    let id: UUID
    let photos: [PhonePhoto]
    init(photo: PhonePhoto, photos: [PhonePhoto]) {
        id = photo.id
        // Present the selection and its photos as one value. A separate @State snapshot can be stale on first presentation.
        let included = photos.contains(where: { $0.id == photo.id }) ? photos : photos + [photo]
        self.photos = included.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
    }
}

extension PhonePhoto {
    func statusText(sendingID: UUID?) -> String {
        if sendingID == id { return "正在传输…" }
        guard receivedByMac else { return "等待 USB 传输" }
        if let stage {
            switch stage {
            case "sent": return "AI 已接收"
            case "submitting": return "正在发送给 AI"
            case "preparing": return "正在上传 AI"
            case "queued": return "排队投递 AI"
            case "uncertain": return "AI 发送待核对"
            case "failed": return "投递失败"
            case "received": return "Mac 已归档"
            default: return stageDetail ?? "Mac 已保存"
            }
        }
        return "Mac 已归档"
    }
    func statusColor(sendingID: UUID?) -> Color {
        if sendingID == id { return .orange }
        guard receivedByMac else { return .secondary }
        if let stage {
            switch stage {
            case "sent": return .green
            case "submitting", "preparing": return .blue
            case "queued": return .teal
            case "uncertain", "failed": return .orange
            default: return .green
            }
        }
        return .green
    }
    func statusIcon(sendingID: UUID?) -> String {
        if sendingID == id { return "arrow.up.circle.fill" }
        guard receivedByMac else { return "clock" }
        if let stage {
            switch stage {
            case "sent": return "checkmark.seal.fill"
            case "submitting", "preparing": return "paperplane.fill"
            case "queued": return "tray.and.arrow.up.fill"
            case "uncertain", "failed": return "exclamationmark.triangle.fill"
            default: return "checkmark.circle.fill"
            }
        }
        return "checkmark.circle.fill"
    }
}

struct LessonPhotoViewer: View {
    @ObservedObject var model: PhoneModel
    let photos: [PhonePhoto]
    @State private var currentID: UUID
    @Environment(\.dismiss) private var dismiss
    init(model: PhoneModel, photos: [PhonePhoto], initialID: UUID) {
        self.model = model; self.photos = photos; _currentID = State(initialValue: initialID)
    }
    private var index: Int { photos.firstIndex(where: { $0.id == currentID }) ?? 0 }
    private var current: PhonePhoto? {
        model.photos.first(where: { $0.id == currentID }) ?? photos.first(where: { $0.id == currentID })
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { geometry in
                    PhotoPager(photos: photos, selectedID: $currentID)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
                VStack(spacing: 10) {
                    HStack {
                        Button { currentID = photos[index - 1].id } label: { Image(systemName: "chevron.left").padding(12) }
                            .disabled(index == 0).accessibilityLabel("上一张")
                        Spacer()
                        VStack(spacing: 4) {
                            Text("\(index + 1) / \(photos.count)").font(.headline.monospacedDigit())
                            if let photo = current {
                                Text(photo.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                                Text(photo.statusText(sendingID: model.sendingID))
                                    .font(.caption.weight(.medium)).foregroundStyle(photo.statusColor(sendingID: model.sendingID))
                            }
                        }
                        Spacer()
                        Button { currentID = photos[index + 1].id } label: { Image(systemName: "chevron.right").padding(12) }
                            .disabled(index + 1 >= photos.count).accessibilityLabel("下一张")
                    }
                    Text("左右滑动切换 · 双击或双指缩放 · 放大后拖动查看")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 20).padding(.bottom, 16)
            }.background(.black)
                .navigationTitle(current?.context?.courseName ?? "历史照片")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("完成") { dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) {
                        if let photo = current {
                            Menu {
                                ShareLink(item: photo.url) { Label("导出当前原图", systemImage: "square.and.arrow.up") }
                                Button("重新传输当前照片") { model.retry(photo) }
                            } label: { Image(systemName: "ellipsis.circle") }
                        }
                    }
                }
        }.preferredColorScheme(.dark).tint(.white)
    }
}

struct SystemCamera: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let onPhoto: (UIImage) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera; picker.cameraDevice = .rear
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: SystemCamera
        init(parent: SystemCamera) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onPhoto(image) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
