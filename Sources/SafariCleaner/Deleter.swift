import Foundation

/// Removes what a scan found: only items marked `deletes`, only paths the guard allows.
enum Deleter {
    static func apply(to report: inout Report) {
        let fm = FileManager.default
        for i in report.items.indices where report.items[i].deletes && report.items[i].status == .found {
            let item = report.items[i]
            var failures: [String] = []
            let targets = item.only ?? (item.contentsOnly ? Scanner.children(of: item.url) : [item.url])
            for url in targets {
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
            let left = (item.only ?? [item.url]).map { Scanner.measure(item.label, $0) }.filter { $0.status == .found }
            let leftBytes = left.reduce(0) { $0 + $1.bytes }
            let leftFiles = left.reduce(0) { $0 + $1.files }
            report.items[i].bytes = max(0, item.bytes - leftBytes)
            report.items[i].files = max(0, item.files - leftFiles)
            if !failures.isEmpty {
                let more = failures.count > 3 ? " и ещё \(failures.count - 3)" : ""
                report.notes.insert("Удалено не всё в «\(item.label)»: " + failures.prefix(3).joined(separator: "; ") + more, at: 0)
            }
        }
    }
}
