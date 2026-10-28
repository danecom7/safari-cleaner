import Foundation

/// Removes what a scan found: only items marked `deletes`, only paths the guard allows.
enum Deleter {
    static func apply(to report: inout Report) {
        let fm = FileManager.default
        for i in report.items.indices where report.items[i].deletes && report.items[i].status == .found {
            let item = report.items[i]
            var failures: [String] = []
            for url in item.contentsOnly ? Scanner.children(of: item.url) : [item.url] {
                guard SafariPaths.isAllowed(url) else {
                    failures.append("\(url.lastPathComponent): пропущено защитой")
                    continue
                }
                do {
                    try fm.removeItem(at: url)
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            // Report what actually went away, not what was planned.
            let left = Scanner.measure(item.label, item.url, contentsOnly: item.contentsOnly)
            let leftBytes = left.status == .found ? left.bytes : 0
            let leftFiles = left.status == .found ? left.files : 0
            report.items[i].bytes = max(0, item.bytes - leftBytes)
            report.items[i].files = max(0, item.files - leftFiles)
            if !failures.isEmpty {
                let more = failures.count > 3 ? " и ещё \(failures.count - 3)" : ""
                report.notes.insert("Удалено не всё в «\(item.label)»: " + failures.prefix(3).joined(separator: "; ") + more, at: 0)
            }
        }
    }
}
