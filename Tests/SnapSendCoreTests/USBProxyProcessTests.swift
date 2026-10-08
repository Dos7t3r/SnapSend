import XCTest
import Darwin
@testable import SnapSendCore

final class USBProxyProcessTests: XCTestCase {
    func testNoisyProxyCanExitWithoutFillingAnUndrainedPipe() throws {
        let process = USBProxyProcess.make(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "dd if=/dev/zero bs=65536 count=32 2>/dev/null; printf error >&2; exit 7"])
        let exited = expectation(description: "noisy proxy exits")
        process.terminationHandler = { _ in exited.fulfill() }
        try process.run()
        wait(for: [exited], timeout: 5)
        XCTAssertEqual(process.terminationStatus, 7)
    }

    func testRepeatedDisconnectWithDetachedExitHandlerDoesNotSpinAtEOF() throws {
        // Exercise the same abrupt lifecycle as WorkspaceModel.disconnect().
        for _ in 0..<20 {
            let process = USBProxyProcess.make(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"])
            try process.run()
            process.terminationHandler = nil
            process.terminate()
            process.waitUntilExit()
        }
        let before = cpuTime()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        let idleCPU = cpuTime() - before
        XCTAssertLessThan(idleCPU, 0.15, "Idle CPU after disconnects: \(idleCPU)s. A retained EOF reader must not run.")
    }

    private func cpuTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}
