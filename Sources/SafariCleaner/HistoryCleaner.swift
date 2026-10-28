import Foundation
import SQLite3

enum HistoryPeriod: CaseIterable, Sendable {
    case lastHour, today, allTime

    var title: String {
        switch self {
        case .lastHour: "последний час"
        case .today: "сегодня"
        case .allTime: "всё время"
        }
    }

    /// Visits at or after this moment are removed. Safari's History.db counts seconds since 2001-01-01,
    /// which is exactly `timeIntervalSinceReferenceDate`.
    var cutoff: Double {
        switch self {
        case .lastHour: Date().addingTimeInterval(-3600).timeIntervalSinceReferenceDate
        case .today: Calendar.current.startOfDay(for: Date()).timeIntervalSinceReferenceDate
        case .allTime: -Double.greatestFiniteMagnitude
        }
    }
}

/// Button 3: visits in the chosen period, pages left without visits, and the favicon cache.
enum HistoryCleaner {
    static let database = SafariPaths.safari.appendingPathComponent("History.db")
    static let favicons = SafariPaths.safari.appendingPathComponent("Favicon Cache")

    /// Test mode runs the exact same edit on a private copy, so its numbers (including how much
    /// the file shrinks) are the real ones. The favicon cache is removed afterwards by `Deleter`.
    static func run(period: HistoryPeriod, testMode: Bool) -> Report {
        var report = Report(title: "Очистка истории за \(period.title)", testMode: testMode)
        let cutoff = period.cutoff
        let verb = testMode ? "Будет удалено" : "Удалено"

        report.items.append(Scanner.measure("Файл истории (из него удаляются записи, сам файл остаётся)",
                                            database, deletes: false, countsAsFreed: false))
        for (suffix, label) in [("-wal", "Служебный файл истории: журнал изменений"), ("-shm", "Служебный файл истории: индекс журнала")] {
            report.items.append(Scanner.measure(label, URL(fileURLWithPath: database.path + suffix),
                                                deletes: false, countsAsFreed: false))
        }
        report.items.append(Scanner.measure("Значки сайтов (Favicon Cache)", favicons, contentsOnly: true))

        let sizeBefore = HistoryDatabase.size(of: database)
        do {
            var sizeAfter: Int64 = 0
            try HistoryDatabase.withCopy(of: database) { copy in
                let s = try HistoryDatabase.stats(copy, cutoff: cutoff)
                report.facts.append("\(verb) посещений: \(s.visitsToDelete) из \(s.totalVisits).")
                report.facts.append("\(verb) страниц: \(s.itemsToDelete) из \(s.totalItems). Это страницы, у которых не осталось ни одного посещения.")
                if s.existingTails > 0 {
                    report.facts.append("Из них «хвостов» (страниц, у которых и до очистки не было посещений): \(s.existingTails).")
                }
                if !s.topSites.isEmpty {
                    report.facts.append("Чаще всего в удаляемой истории: " + s.topSites.map { "\($0.0) (\($0.1))" }.joined(separator: ", ") + ".")
                }
                if testMode {
                    try HistoryDatabase.edit(copy, cutoff: cutoff)
                    sizeAfter = HistoryDatabase.size(of: copy)
                }
            }
            if !testMode {
                try HistoryDatabase.editWithBackup(database, cutoff: cutoff)
                sizeAfter = HistoryDatabase.size(of: database)
            }
            var shrink = ScanItem(label: "Уменьшение файла истории после сжатия", url: database, deletes: false)
            shrink.status = .found
            shrink.bytes = max(0, sizeBefore - sizeAfter)
            report.items.append(shrink)
        } catch {
            report.facts.append("Не удалось \(testMode ? "проверить" : "очистить") историю: \(error.localizedDescription)")
        }

        report.items.removeAll { $0.status == .missing }
        report.notes = [
            "iCloud: история удаляется только на этом Mac. На iPhone и iPad она останется и при синхронизации может вернуться сюда.",
            "Значки сайтов удаляются все, независимо от выбранного периода: по ним нельзя понять, когда вы заходили на сайт.",
            "Служебные файлы -wal и -shm: изменения проходят через саму базу SQLite, затем журнал сбрасывается, а файл сжимается, чтобы удалённые записи не оставались внутри.",
            "Файл истории уменьшается даже при очистке за короткий период: со временем в нём накапливается пустое место, которое Safari сам не убирает, а сжатие его освобождает.",
            "Перед изменением делается резервная копия файла истории в ~/Library/Application Support/SafariCleaner. Если что-то пойдёт не так, она возвращается на место, а после успешной очистки сразу удаляется.",
            "Не трогаем, хотя по ним тоже видно, где вы были: Touch Icons Cache, Template Icons, WebpageIcons.db, Link Presentation Icons, «Часто посещаемые» (TopSites.plist), недавно закрытые вкладки. Скажите, если нужно добавить.",
        ]
        if testMode {
            report.notes.append("Уменьшение файла истории посчитано на временной копии той же операцией, что выполняется при настоящей очистке.")
        }
        let profiles = Scanner.children(of: SafariPaths.container.appendingPathComponent("Safari/Profiles"))
            .filter { $0.lastPathComponent != "DefaultProfile" }
        if !profiles.isEmpty {
            report.notes.append("Найдены дополнительные профили Safari (\(profiles.count)). Их история пока не учитывается.")
        }
        return report
    }
}

/// All work with History.db goes through SQLite, so the -wal and -shm files are always handled consistently.
enum HistoryDatabase {
    struct Stats {
        var totalVisits = 0, visitsToDelete = 0, totalItems = 0, itemsToDelete = 0, existingTails = 0
        var topSites: [(String, Int)] = []
    }

    /// Disk space taken by the database together with its -wal and -shm files.
    static func size(of database: URL) -> Int64 {
        ["", "-wal", "-shm"].reduce(0) { total, suffix in
            let values = try? URL(fileURLWithPath: database.path + suffix).resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            return total + Int64(values?.totalFileAllocatedSize ?? 0)
        }
    }

    /// Runs `body` on a private copy (the -wal journal holds the newest records, so it's copied too;
    /// -shm is rebuilt by SQLite). The copy is removed afterwards.
    static func withCopy(of database: URL, _ body: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("SafariCleaner-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let copy = temp.appendingPathComponent("History.db")
        try fm.copyItem(at: database, to: copy)
        if fm.fileExists(atPath: database.path + "-wal") {
            try fm.copyItem(atPath: database.path + "-wal", toPath: copy.path + "-wal")
        }
        try body(copy)
    }

    static func stats(_ database: URL, cutoff: Double) throws -> Stats {
        try SQLiteDB.open(database) { db in
            var s = Stats()
            s.totalVisits = try db.count("SELECT COUNT(*) FROM history_visits")
            s.visitsToDelete = try db.count("SELECT COUNT(*) FROM history_visits WHERE visit_time >= ?1", [cutoff])
            s.totalItems = try db.count("SELECT COUNT(*) FROM history_items")
            s.itemsToDelete = try db.count("""
                SELECT COUNT(*) FROM history_items i WHERE NOT EXISTS
                  (SELECT 1 FROM history_visits v WHERE v.history_item = i.id AND v.visit_time < ?1)
                """, [cutoff])
            s.existingTails = try db.count("""
                SELECT COUNT(*) FROM history_items i WHERE NOT EXISTS
                  (SELECT 1 FROM history_visits v WHERE v.history_item = i.id)
                """)

            var perHost: [String: Int] = [:]
            try db.query("""
                SELECT i.url, COUNT(*) FROM history_visits v JOIN history_items i ON i.id = v.history_item
                WHERE v.visit_time >= ?1 GROUP BY i.id
                """, [cutoff]) { stmt in
                guard let text = sqlite3_column_text(stmt, 0),
                      var host = URL(string: String(cString: text))?.host else { return }
                if host.hasPrefix("www.") { host.removeFirst(4) }
                perHost[host, default: 0] += Int(sqlite3_column_int64(stmt, 1))
            }
            s.topSites = Array(perHost.sorted { $0.value > $1.value }.prefix(10).map { ($0.key, $0.value) })
            return s
        }
    }

    /// Deletes visits from `cutoff` on and every page left without visits, then compacts the file
    /// and empties the -wal journal so nothing deleted stays inside.
    static func edit(_ database: URL, cutoff: Double) throws {
        try SQLiteDB.open(database) { db in
            // Safari's schema relies on cascades: redirects between visits, page tags.
            try db.query("PRAGMA foreign_keys = ON")
            try db.query("BEGIN IMMEDIATE")
            do {
                // Pages that keep older visits: let Safari recount their visit statistics.
                try db.query("""
                    UPDATE history_items SET should_recompute_derived_visit_counts = 1
                    WHERE id IN (SELECT history_item FROM history_visits WHERE visit_time >= ?1)
                    """, [cutoff])
                try db.query("DELETE FROM history_visits WHERE visit_time >= ?1", [cutoff])
                try db.query("DELETE FROM history_items WHERE id NOT IN (SELECT history_item FROM history_visits)")
                try db.query("COMMIT")
            } catch {
                try? db.query("ROLLBACK")
                throw error
            }
            try db.query("VACUUM")
            try db.query("PRAGMA wal_checkpoint(TRUNCATE)")
            var check = ""
            try db.query("PRAGMA quick_check") { stmt in
                if let text = sqlite3_column_text(stmt, 0) { check = String(cString: text) }
            }
            guard check == "ok" else { throw CleanerError("проверка целостности файла не пройдена (\(check))") }
        }
    }

    /// `edit` on the live file with a safety copy: restored on any failure, removed on success.
    static func editWithBackup(_ database: URL, cutoff: Double) throws {
        let files = ["", "-wal", "-shm"].map { URL(fileURLWithPath: database.path + $0) }
        try Backup.protect(files, named: "History") { try edit(database, cutoff: cutoff) }
    }
}

/// Minimal SQLite wrapper: one connection, closed when `open`'s body returns.
private final class SQLiteDB {
    private let handle: OpaquePointer

    private init(_ handle: OpaquePointer) { self.handle = handle }

    static func open<T>(_ url: URL, _ body: (SQLiteDB) throws -> T) throws -> T {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw CleanerError("файл истории не открывается")
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 5000)
        return try body(SQLiteDB(handle))
    }

    func query(_ sql: String, _ args: [Double] = [], row: (OpaquePointer) -> Void = { _ in }) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw CleanerError("формат истории не распознан (\(String(cString: sqlite3_errmsg(handle))))")
        }
        defer { sqlite3_finalize(stmt) }
        for (index, value) in args.enumerated() { sqlite3_bind_double(stmt, Int32(index + 1), value) }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW { row(stmt); continue }
            if rc == SQLITE_DONE { return }
            throw CleanerError("ошибка базы истории (\(String(cString: sqlite3_errmsg(handle))))")
        }
    }

    func count(_ sql: String, _ args: [Double] = []) throws -> Int {
        var n = 0
        try query(sql, args) { n = Int(sqlite3_column_int64($0, 0)) }
        return n
    }
}
