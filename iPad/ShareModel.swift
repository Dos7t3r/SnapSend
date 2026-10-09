import SwiftUI
import UIKit
import Network
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class ShareModel: ObservableObject {
    @Published var images: [SharedImage] = []
    @Published var preview: UIImage?
    @Published var status = "正在读取分享图片…"
    @Published var error: String?
    @Published var pairingCode: String?
    @Published var context: LessonContext?
    @Published var connected = false
    @Published var importing = true
    @Published var transferring = false
    @Published var completed = 0
    private let storageDirectory: URL?
    private let loadPairings: () throws -> [String:String]
    private let savePairings: ([String:String]) throws -> Void
    init(directory: URL? = nil, loadPairings: @escaping () throws -> [String:String] = PairingVault.load,
         savePairings: @escaping ([String:String]) throws -> Void = PairingVault.save) {
        storageDirectory = directory; self.loadPairings = loadPairings; self.savePairings = savePairings
    }
    private var storage: ShareStorage?
    private let transport = ShareTransport()
    private var listener: NWListener?
    private var connection: NWConnection?
    private var commands = Data()
    private var trusted: [String:String] = [:]
    private var peerID: UUID?
    private var challenge: PairingChallenge?
    private var proof = ""
    private var authenticated = false
    private var contextSynced = false
    private var requested = false
    private var stopped = false
    private var sendingID: UUID?
    private var transfer: Task<Void,Never>?
    private var deadline: Task<Void,Never>?
    private var loading: Task<Void,Never>?
    private var providers: [NSItemProvider] = []
    private var loadingProgress: Progress?
    private var failures = 0
    private var blockedUntil = Date.distantPast
    private let deviceID: UUID = {
        let defaults = UserDefaults.standard
        if let value = defaults.string(forKey: "SnapSendShareID"), let id = UUID(uuidString: value) { return id }
        let id = UUID(); defaults.set(id.uuidString, forKey: "SnapSendShareID"); return id
    }()

    func start(items: [NSExtensionItem]) {
        guard loading == nil, storage == nil else { return }
        providers = items.flatMap { $0.attachments ?? [] }
        loading = Task {
            do {
                guard !providers.isEmpty, providers.count <= 5, providers.allSatisfy({ $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }) else { throw ShareFile.Failure.unsupported }
                trusted = try loadPairings()
                let directory = storageDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("SharedImages")
                let store = try ShareStorage(directory: directory); storage = store
                for provider in providers {
                    try Task.checkCancellation()
                    let image = try await importFile(provider, into: store)
                    guard !stopped else { return }
                    if preview == nil { preview = await Self.thumbnail(await store.url(image)) }
                }
                images = await store.snapshot(); importing = false
                status = "图片已保留 · 等待 USB 连接"; startServer()
            } catch {
                guard !stopped else { return }
                self.error = error.localizedDescription; importing = false
                if let storage { images = await storage.snapshot() }
            }
        }
    }
    private func importFile(_ provider: NSItemProvider, into storage: ShareStorage) async throws -> SharedImage {
        // Provider URL is valid only inside completion. Copy before returning, then inspect on actor.
        let staged: URL = try await withCheckedThrowingContinuation { continuation in
            loadingProgress = provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, error in
                do {
                    if let error { throw error }
                    guard let url else { throw ShareFile.Failure.unsupported }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size > 0, size <= ShareFile.limit else { throw ShareFile.Failure.tooLarge }
                    let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.copyItem(at: url, to: target)
                    continuation.resume(returning: target)
                } catch { continuation.resume(throwing: error) }
            }
        }
        defer { try? FileManager.default.removeItem(at: staged) }
        try Task.checkCancellation()
        return try await storage.add(staged)
    }
    private nonisolated static func thumbnail(_ url: URL) async -> UIImage? {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString:Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 16000, height <= 16000, width * height <= 100_000_000,
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways:true, kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:480] as CFDictionary) else { return nil }
            return UIImage(cgImage: image)
        }.value
    }
    func startServer() {
        guard listener == nil, !stopped else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 27184)
            let server = try NWListener(using: parameters); listener = server
            server.stateUpdateHandler = { [weak self, weak server] state in Task { @MainActor in
                guard let self, let server, self.listener === server else { return }
                if case .failed(let error) = state { self.error = "USB 服务失败：\(error.localizedDescription)"; server.cancel(); self.listener = nil; self.close() }
            } }
            server.newConnectionHandler = { [weak self] incoming in Task { @MainActor in self?.accept(incoming) } }
            server.start(queue: .main)
        } catch { self.error = error.localizedDescription }
    }
    private func accept(_ incoming: NWConnection) {
        guard connection == nil, !stopped else { incoming.cancel(); return }
        connection = incoming; commands = Data(); contextSynced = false; authenticated = false; peerID = nil; proof = ""
        incoming.stateUpdateHandler = { [weak self, weak incoming] state in Task { @MainActor in
            guard let self, let incoming, self.connection === incoming else { return }
            switch state { case .ready: self.read(incoming); case .failed, .cancelled: self.close(); default: break }
        } }
        incoming.start(queue: .main); timeout(12)
    }
    private func read(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak conn] data, _, done, error in Task { @MainActor in
            guard let self, let conn, self.connection === conn else { return }
            if let data {
                self.commands.append(data)
                guard self.commands.count <= 8192 else { self.close(); return }
                while let index = self.commands.firstIndex(of: 10) {
                    let line = String(data: self.commands.prefix(upTo: index), encoding: .utf8) ?? ""
                    self.commands = Data(self.commands.dropFirst(index + 1))
                    do { try await self.handle(line, conn) } catch { self.error = error.localizedDescription; self.close(); return }
                    guard self.connection === conn else { return }
                }
            }
            if done || error != nil { self.close() } else { self.read(conn) }
        } }
    }
    private func control(_ kind: String, secret: String? = nil) throws {
        var header = WireHeader(kind: kind); header.deviceID = deviceID; header.secret = secret
        if kind == "hello" { header.challenge = proof }
        if kind == "pairing" { header.message = "在 Mac 输入 iPad 分享面板的 6 位验证码" }
        connection?.send(content: try WireEncoder.encode(header), completion: .contentProcessed { _ in })
    }
    private func pair() throws {
        guard Date() >= blockedUntil else { throw ShareError.message("验证码尝试过多，请一分钟后重试") }
        challenge = PairingChallenge(); pairingCode = challenge?.code
        status = "首次配对 · 在 Mac 输入验证码"; try control("pairing"); timeout(60)
    }
    private func authorize() throws {
        authenticated = true; connected = true; pairingCode = nil; challenge = nil; error = nil
        try control("ready"); status = "已连接 · 正在读取 Mac 目标"; timeout(12)
    }
    private func handle(_ line: String, _ conn: NWConnection) async throws {
        if !authenticated {
            if line.hasPrefix("HELLO "), peerID == nil {
                let parts = line.split(separator: " ")
                guard parts.count == 3, let id = UUID(uuidString: String(parts[1])), let name = Data(base64Encoded: String(parts[2])), name.count <= 256, String(data:name,encoding:.utf8) != nil else { throw ShareError.message("连接信息无效") }
                peerID = id
                if trusted[id.uuidString] != nil { proof = try PairingCrypto.secret(); try control("hello") } else { try pair() }
            } else if line == "PAIRING", peerID != nil { try pair() }
            else if line.hasPrefix("PROVE "), let id = peerID, let secret = trusted[id.uuidString], !proof.isEmpty,
                    PairingCrypto.matches(String(line.dropFirst(6)), secret: secret, challenge: proof) { try authorize() }
            else if line.hasPrefix("PAIR "), let id = peerID, var challenge {
                let approved = challenge.verify(String(line.dropFirst(5))); self.challenge = challenge
                guard approved else {
                    failures += 1
                    if failures >= 3 || Date() >= challenge.expiresAt { blockedUntil = Date().addingTimeInterval(60); failures = 0; throw ShareError.message("验证码无效，请一分钟后重连") }
                    error = "验证码不正确，请重试"; try control("pairing"); return
                }
                let secret = try PairingCrypto.secret(); var next = trusted; next[id.uuidString] = secret
                try savePairings(next); trusted = next; failures = 0
                try control("paired", secret: secret); try authorize()
            } else { throw ShareError.message("认证失败，请在 Mac 重新连接") }
        } else if line.hasPrefix("CONTEXT ") {
            let value = String(line.dropFirst(8))
            if value == "-" { context = nil }
            else {
                guard let bytes = Data(base64Encoded:value), bytes.count <= 4096 else { throw ShareError.message("课堂信息无效") }
                context = try JSONDecoder().decode(LessonContext.self, from:bytes)
            }
            contextSynced = true; if sendingID == nil { deadline?.cancel(); status = "已连接 · 可以保存到 Mac"; sendNext() }
        } else if line.hasPrefix("RECEIVED "), let id = UUID(uuidString:String(line.dropFirst(9))), id == sendingID, let storage {
            try await storage.remove(id)
            images = await storage.snapshot()
            guard connection === conn else { return }
            deadline?.cancel(); sendingID = nil; completed += 1; sendNext()
        } else if line.hasPrefix("STATUS ") { /* Mac archive receipt is the only completion gate. */ }
        else { throw ShareError.message("收到无效接收回执") }
    }
    func beginTransfer() {
        guard !importing, connected, contextSynced else { return }
        requested = true; error = nil; sendNext()
    }
    private func sendNext() {
        guard requested, authenticated, contextSynced, sendingID == nil, let conn = connection, let storage else { return }
        guard let item = images.first else { requested = false; transferring = false; status = "已保存到 Mac · 本次不自动发送 AI"; return }
        sendingID = item.id; transferring = true; status = "正在传输 · 还有 \(images.count) 张"; timeout(60)
        let target = context?.lesson.id
        transfer = Task {
            do {
                let url = await storage.url(item)
                try await transport.send(item, at:url, session:target, over:conn)
            } catch { guard connection === conn else { return }; self.error = error.localizedDescription; close() }
        }
    }
    private func timeout(_ seconds: Double) {
        deadline?.cancel(); deadline = Task { [weak self] in
            do { try await Task.sleep(for:.seconds(seconds)) } catch { return }
            self?.error = "连接或接收超时，图片已保留，点击重试"; self?.close()
        }
    }
    private func close() {
        deadline?.cancel(); deadline = nil; transfer?.cancel(); transfer = nil
        connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil
        connected = false; authenticated = false; contextSynced = false; requested = false; transferring = false; sendingID = nil; pairingCode = nil
        status = "等待 USB · 未确认的图片仍保留"
    }
    func retry() { close(); error = nil; startServer() }
    func deletePending() {
        guard !transferring, !importing, let storage else { return }
        Task {
            do { for image in images { try await storage.remove(image.id) }; images = await storage.snapshot(); preview = nil }
            catch { self.error = error.localizedDescription }
        }
    }
    func stop() {
        stopped = true; loading?.cancel(); loadingProgress?.cancel(); loading = nil
        listener?.stateUpdateHandler = nil; listener?.cancel(); listener = nil; close(); preview = nil
    }
    enum ShareError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
    }
}
