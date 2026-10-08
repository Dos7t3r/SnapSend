import Foundation

// stdout is exclusively Chrome's length-prefixed protocol; never print diagnostics there.
func readExact(_ count: Int) -> Data? {
    var result = Data()
    while result.count < count {
        let part = FileHandle.standardInput.readData(ofLength: count - result.count)
        if part.isEmpty { return nil }; result.append(part)
    }
    return result
}
func reply(_ value: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: value), data.count < 1_000_000 else { return }
    var length = UInt32(data.count).littleEndian
    FileHandle.standardOutput.write(Data(bytes: &length, count: 4))
    FileHandle.standardOutput.write(data)
}
var endpointFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SnapSend/bridge.json")
#if DEBUG
if let override = ProcessInfo.processInfo.environment["SNAPSEND_TEST_ENDPOINT"] { endpointFile = URL(fileURLWithPath: override) }
#endif
while let prefix = readExact(4) {
    let length = prefix.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
    guard length > 0, length <= 64 * 1024, let payload = readExact(Int(length)) else { break }
    do {
        let endpoint = try JSONSerialization.jsonObject(with: Data(contentsOf: endpointFile)) as? [String: Any]
        guard let token = endpoint?["token"] as? String else { throw CocoaError(.fileReadNoSuchFile) }
        let port = (endpoint?["port"] as? Int) ?? 27184
        guard port > 0, port <= 65535 else { throw CocoaError(.fileReadCorruptFile) }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/command")!)
        request.httpMethod = "POST"; request.httpBody = payload; request.timeoutInterval = 8
        request.setValue(token, forHTTPHeaderField: "X-SnapSend-Token")
        let resultFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        // Synchronous CLI host lifecycle, separate from the Mac UI process.
        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.downloadTask(with: request) { url, _, _ in
            if let url { try? FileManager.default.moveItem(at: url, to: resultFile) }
            semaphore.signal()
        }
        task.resume(); semaphore.wait()
        defer { try? FileManager.default.removeItem(at: resultFile) }
        let data = try Data(contentsOf: resultFile)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        reply(object)
    } catch { reply(["ok": false, "error": "请打开新版 SnapSend；如果仍无法连接，请在 Mac 中重新安装浏览器桥接。"] ) }
}
