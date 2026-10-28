import AppKit
import Darwin

enum SafariProcess {
    static let bundleID = "com.apple.Safari"
    /// Background service that keeps History.db open while Safari runs.
    static let historyService = "com.apple.Safari.History"

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    static var isHistoryServiceRunning: Bool { isProcessRunning(executable: historyService) }

    /// Same as ⌘Q: Safari saves its session and may ask about unsent forms.
    static func quit() {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.terminate() }
    }

    /// Waits for Safari (and, if asked, its history service) to exit.
    /// After an actual wait, gives WebKit a moment to finish writing cookies to disk.
    static func waitUntilClosed(includingHistoryService: Bool, timeout: TimeInterval = 20) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var waited = false
        while isRunning || (includingHistoryService && isHistoryServiceRunning) {
            if Date() > deadline { return false }
            waited = true
            try? await Task.sleep(for: .milliseconds(250))
        }
        if waited { try? await Task.sleep(for: .seconds(2)) }
        return true
    }

    private static func isProcessRunning(executable name: String) -> Bool {
        let capacity = 8192
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for pid in pids.prefix(max(0, count)) where pid > 0 {
            if proc_pidpath(pid, &path, UInt32(path.count)) > 0, String(cString: path).hasSuffix("/" + name) {
                return true
            }
        }
        return false
    }
}
