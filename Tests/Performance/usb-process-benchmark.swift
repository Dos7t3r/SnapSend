import Foundation
import Darwin

private final class CallbackCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var callbacks = 0
    private var eof = 0
    func record(_ data: Data) { lock.withLock { callbacks += 1; if data.isEmpty { eof += 1 } } }
    var snapshot: (Int, Int) { lock.withLock { (callbacks, eof) } }
}

@main struct USBProcessBenchmark {
    static func main() throws {
        let legacy = CommandLine.arguments.contains("--legacy")
        let counter = CallbackCounter()
        let executable = URL(fileURLWithPath: "/bin/sh")
        let arguments = ["-c", "printf ready; sleep 0.05"]
        let process: Process
        var pipe: Pipe?
        if legacy {
            // Bounded reproduction of the original EOF reader. Never used by the app.
            let output = Pipe(); pipe = output
            process = Process(); process.executableURL = executable; process.arguments = arguments
            output.fileHandleForReading.readabilityHandler = { handle in counter.record(handle.availableData) }
            process.standardOutput = output; process.standardError = output
        } else {
            process = USBProxyProcess.make(executable: executable, arguments: arguments)
        }
        process.terminationHandler = nil
        let start = cpuTime()
        try process.run()
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        let elapsed = cpuTime() - start
        pipe?.fileHandleForReading.readabilityHandler = nil
        let counts = counter.snapshot
        print("mode=\(legacy ? "legacy" : "fixed") wall=3s callbacks=\(counts.0) EOF=\(counts.1) CPU-seconds=\(elapsed)")
    }

    private static func cpuTime() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}
