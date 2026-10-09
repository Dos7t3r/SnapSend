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
    @Published var pairingExpiresAt: Date?
    @Published var lastSavedID: UUID?
    @Published var savingCount = 0
    @Published var aiArrivalID: UUID?
    @Published var pairingCode: String?
    @Published var peerName = ""
    @Published var pairedPeerName = ""
    @Published var activeContext: LessonContext?
    private var trusted: [String: String] = [:]
    private var peerID: UUID?
    private var proofChallenge = ""
    private var pairChallenge: PairingChallenge?
    private var contextSynced = false
    private var failedAttempts = 0
    private var blockedUntil = Date.distantPast
    let deviceID: UUID
    private var storage: PhoneStorage?
    private var listener: NWListener?
    private var connection: NWConnection?
    private var commandBuffer = Data()
    private var authenticated = false
    private var deadline: Task<Void, Never>?
    var pendingCount: Int { photos.filter { !$0.receivedByMac }.count }

    init(preview: Bool = false) {
        if preview { deviceID = UUID(); status = "USB 服务已就绪 · 等待 Mac 连接"; return }
        let defaults = UserDefaults.standard
        pairedPeerName = defaults.string(forKey: "SnapSendPairedPeerName") ?? ""
        if let saved = defaults.string(forKey: "SnapSendPhoneID"), let id = UUID(uuidString: saved) { deviceID = id }
        else { deviceID = UUID(); defaults.set(deviceID.uuidString, forKey: "SnapSendPhoneID") }
        if let value = defaults.data(forKey: "SnapSendLastClass") {
            activeContext = try? JSONDecoder().decode(LessonContext.self, from: value)
        }
        do { trusted = try PairingVault.load() }
        catch { errorMessage = "设备记忆读取失败：\(error.localizedDescription)" }
        Task {
            do {
                let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("PendingPhotos")
                let storage = try await Task.detached(priority: .utility) { try PhoneStorage(directory: folder) }.value
                self.storage = storage; photos = await storage.snapshot(); startServer(); sendNext()
            } catch { errorMessage = "无法读取照片历史：\(error.localizedDescription)" }
        }
    }
    func save(_ image: UIImage, context: LessonContext?, quality: Double = 0.9, sendToAI: Bool = true) {
        savingCount += 1
        let background = UIApplication.shared.beginBackgroundTask(withName: "保存课堂照片")
        Task {
            defer { savingCount -= 1; if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
            guard let storage else { errorMessage = "照片存储尚未就绪，请稍后重试"; return }
            do { photos = try await storage.save(image, context: context, quality: quality, sendToAI: sendToAI); lastSavedID = photos.last?.id; errorMessage = nil; sendNext() }
            catch { errorMessage = "保存失败：\(error.localizedDescription)" }
        }
    }
    func save(_ data: Data, context: LessonContext?, quality: Double = 0.9, sendToAI: Bool = true) {
        savingCount += 1
        let background = UIApplication.shared.beginBackgroundTask(withName: "保存课堂照片")
        Task {
            defer { savingCount -= 1; if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
            guard let storage else { errorMessage = "照片存储尚未就绪，请稍后重试"; return }
            do { photos = try await storage.save(data, context: context, quality: quality, sendToAI: sendToAI); lastSavedID = photos.last?.id; errorMessage = nil; sendNext() }
            catch { errorMessage = "保存失败：\(error.localizedDescription)" }
        }
    }
    var storageReady: Bool { storage != nil }
    #if DEBUG || targetEnvironment(simulator)
    func configureTesting(directory: URL) async throws {
        storage = try PhoneStorage(directory: directory)
        photos = await storage!.snapshot()
    }
    #endif
    func startServer() {
        guard listener == nil, UIApplication.shared.applicationState != .background else { return }
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
        pairingCode = nil; pairingExpiresAt = nil; pairChallenge = nil; peerID = nil; contextSynced = false
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
                        await self.handle(line, connection: conn)
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
        pairingExpiresAt = pairChallenge?.expiresAt
        status = "首次配对 · 在 Mac 输入下方验证码"
        sendControl("pairing", message: "请输入手机上的 6 位验证码，60 秒内有效。")
        armDeadline(seconds: 60, message: "验证码已过期，重新连接即可获取新验证码")
    }
    private func authorize() {
        pairedPeerName = peerName; UserDefaults.standard.set(peerName, forKey: "SnapSendPairedPeerName")
        authenticated = true; connected = true; errorMessage = nil; pairingCode = nil; pairingExpiresAt = nil; pairChallenge = nil
        deadline?.cancel(); deadline = nil
        UIApplication.shared.isIdleTimerDisabled = false
        status = "USB 已连接 · 正在同步课堂"
        sendControl("ready")
        // Wait for Mac's current class before starting transmission.
        armDeadline(seconds: 12, message: "课堂同步超时，请重新连接")
    }
    func forgetPairings() {
        do { try PairingVault.save([:]); trusted = [:]; pairedPeerName = ""; UserDefaults.standard.removeObject(forKey: "SnapSendPairedPeerName"); closeConnection(); status = "已忘记设备 · 下次连接使用新验证码" }
        catch { errorMessage = "无法更新配对记录：\(error.localizedDescription)" }
    }
    func retry(_ photo: PhonePhoto) {
        guard photo.stage != "uncertain", photo.stage != "failed", photo.stage != "sent" else {
            errorMessage = "AI 投递请在 Mac 核对或重发，避免重复发送"; return
        }
        Task { do { if let storage { photos = try await storage.requeue(photo.id) }; sendNext() }
            catch { errorMessage = "无法重新排队：\(error.localizedDescription)" } }
    }
    private func handle(_ line: String, connection conn: NWConnection) async {
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
                    if let storage { photos = try await storage.updateContext(context) }
                    activeContext = context
                    UserDefaults.standard.set(data, forKey: "SnapSendLastClass")
                }
                guard connection === conn else { return }
                contextSynced = true
                if sendingID == nil { deadline?.cancel(); deadline = nil; sendNext() }
            } catch { reject("课堂同步失败") }
        } else if line.hasPrefix("RECEIVED "), let id = UUID(uuidString: String(line.dropFirst(9))), id == sendingID {
            do {
                if let storage { photos = try await storage.acknowledge(id) }
                guard connection === conn else { return }
                deadline?.cancel(); deadline = nil; sendingID = nil; UIApplication.shared.isIdleTimerDisabled = false; sendNext()
            } catch { errorMessage = "接收状态保存失败：\(error.localizedDescription)"; closeConnection() }
        } else if line.hasPrefix("STATUS ") {
            let parts = line.split(separator: " ", maxSplits: 3)
            if parts.count >= 3, let id = UUID(uuidString: String(parts[1])) {
                let stage = String(parts[2])
                let detail: String
                if parts.count >= 4, let data = Data(base64Encoded: String(parts[3])), let text = String(data: data, encoding: .utf8) {
                    detail = text
                } else { detail = "" }
                let alreadySent = photos.first { $0.id == id }?.stage == "sent"
                do { if let storage { photos = try await storage.stage(id, stage, detail) } }
                catch { errorMessage = "状态保存失败：\(error.localizedDescription)" }
                if stage == "sent", !alreadySent { aiArrivalID = id }

            }
        } else { reject("收到不合法的传输确认") }
    }
    private func sendNext() {
        guard authenticated, contextSynced, sendingID == nil, let conn = connection, let storage else { return }
        guard let photo = photos.first(where: { !$0.receivedByMac }) else {
            status = activeContext == nil ? "已连接 · 未指定目标，照片进入收件箱" : "照片已同步 · 可以继续拍照"; return
        }
        sendingID = photo.id; UIApplication.shared.isIdleTimerDisabled = true
        status = "正在传输 · 还剩 \(pendingCount) 张"
        armDeadline(seconds: 60, message: "Mac 接收确认超时，照片保留，重新连接即可重试")
        Task {
            do {
                let frame = try await storage.frame(photo)
                guard connection === conn, authenticated, sendingID == photo.id else { return }
                conn.send(content: frame, completion: .contentProcessed { [weak self, weak conn] error in
                    Task { @MainActor in
                        guard let self, let conn, self.connection === conn, let error else { return }
                        self.errorMessage = "传输失败：\(error.localizedDescription)"; self.closeConnection()
                    }
                })
            } catch {
                guard connection === conn else { return }
                errorMessage = "照片读取失败：\(error.localizedDescription)"; closeConnection()
            }
        }
    }
}
