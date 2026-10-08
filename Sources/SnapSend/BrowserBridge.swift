import Foundation
import Network

@MainActor
final class BrowserBridge {
    private var listener: NWListener?
    private let token = UUID().uuidString + UUID().uuidString
    var command: (([String: Any]) -> [String: Any])?
    var failure: ((String) -> Void)?
    func start(endpointFile: URL? = nil, port: UInt16 = 27184) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let file = endpointFile ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SnapSend/bridge.json")
        let base = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let endpointData = try JSONSerialization.data(withJSONObject: ["token": token, "port": port])
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    do {
                        try endpointData.write(to: file, options: .atomic)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                    } catch { self?.failure?("浏览器桥接配置写入失败，请检查本地目录权限。") }
                case .failed: self?.failure?("浏览器桥接端口被占用，请退出其他 SnapSend 窗口后重开。")
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.read(connection, buffer: Data()); connection.start(queue: .main) }
        }
        listener.start(queue: .main)
    }
    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                var buffer = buffer; if let data { buffer.append(data) }
                guard buffer.count <= 65536 else { connection.cancel(); return }
                if let range = buffer.range(of: Data("\r\n\r\n".utf8)),
                   let head = String(data: buffer[..<range.lowerBound], encoding: .utf8) {
                    let lines = head.components(separatedBy: "\r\n")
                    let headers = lines.dropFirst().reduce(into: [String: String]()) { result, line in
                        let parts = line.split(separator: ":", maxSplits: 1)
                        if parts.count == 2 { result[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces) }
                    }
                    guard lines.first == "POST /command HTTP/1.1", headers["x-snapsend-token"] == self.token,
                          let size = Int(headers["content-length"] ?? ""), size > 0, size < 60000 else { connection.cancel(); return }
                    let body = buffer[range.upperBound...]
                    if body.count >= size {
                        let message = (try? JSONSerialization.jsonObject(with: Data(body.prefix(size)))) as? [String: Any]
                        let response = message.map { self.command?($0) ?? ["ok": false] } ?? ["ok": false]
                        let encoded = (try? JSONSerialization.data(withJSONObject: response)) ?? Data("{}".utf8)
                        let header = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(encoded.count)\r\nConnection: close\r\n\r\n".utf8)
                        connection.send(content: header + encoded, completion: .contentProcessed { _ in connection.cancel() }); return
                    }
                }
                if done || error != nil { connection.cancel() } else { self.read(connection, buffer: buffer) }
            }
        }
        // Bound idle clients as well as their payload size.
        if buffer.isEmpty { Task { try? await Task.sleep(for: .seconds(10)); connection.cancel() } }
    }
}
