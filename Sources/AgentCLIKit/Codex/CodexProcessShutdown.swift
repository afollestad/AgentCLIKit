import Darwin
import Foundation

enum CodexProcessShutdown {
    static func waitForExitOrKill(_ process: Process, timeout: TimeInterval) async {
        let sleepNanoseconds: UInt64 = 50_000_000
        let attempts = max(1, Int(timeout * 1_000_000_000 / Double(sleepNanoseconds)))
        for _ in 0..<attempts {
            guard process.isRunning else {
                return
            }
            try? await Task.sleep(nanoseconds: sleepNanoseconds)
        }
        guard process.isRunning else {
            return
        }
        Darwin.kill(process.processIdentifier, SIGKILL)
    }
}
