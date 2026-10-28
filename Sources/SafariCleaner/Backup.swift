import Foundation

struct CleanerError: LocalizedError {
    let errorDescription: String?
    init(_ text: String) { errorDescription = text }
}

/// Safety copies for files that are edited in place (History.db, Cookies.binarycookies).
enum Backup {
    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SafariCleaner", isDirectory: true)

    /// Runs `edit` with a copy of `files` saved first: restored on any failure, removed on success.
    static func protect(_ files: [URL], named name: String, _ edit: () throws -> Void) throws {
        let fm = FileManager.default
        let backup = folder.appendingPathComponent("\(name)-backup", isDirectory: true)
        try? fm.removeItem(at: backup)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        for file in files where fm.fileExists(atPath: file.path) {
            try fm.copyItem(at: file, to: backup.appendingPathComponent(file.lastPathComponent))
        }
        do {
            try edit()
        } catch {
            do {
                for file in files {
                    let saved = backup.appendingPathComponent(file.lastPathComponent)
                    if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
                    if fm.fileExists(atPath: saved.path) { try fm.copyItem(at: saved, to: file) }
                }
            } catch let restoreError {
                throw CleanerError("\(error.localizedDescription). Вернуть резервную копию не удалось (\(restoreError.localizedDescription)), она лежит в \(backup.path)")
            }
            try? fm.removeItem(at: backup)
            throw CleanerError("\(error.localizedDescription). Ничего не изменено: файл восстановлен из резервной копии.")
        }
        try? fm.removeItem(at: backup)
    }
}
