import Foundation

@main
struct BridgeHarness {
    @MainActor static func main() async throws {
        let bridge = BrowserBridge()
        bridge.command = { message in ["ok": true, "echo": message["kind"] ?? "", "jpeg": Data(repeating: 17, count: 680000).base64EncodedString()] }
        try bridge.start(endpointFile: URL(fileURLWithPath: CommandLine.arguments[1]), port: 27185)
        try await Task.sleep(for: .seconds(30))
    }
}
