#if os(macOS)
import Foundation

/// iproxy output is deliberately discarded. A Pipe readability handler kept alive
/// after EOF can spin continuously, especially when disconnect detaches exit handlers.
public enum USBProxyProcess {
    public static func make(executable: URL, arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        return process
    }
}
#endif
