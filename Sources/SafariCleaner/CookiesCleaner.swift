import Foundation

/// Button 2: Safari's cookies plus website data (local storage, site databases, service workers).
/// Sites from the whitelist keep both.
enum CookiesCleaner {
    static let cookieFile = SafariPaths.cookies.appendingPathComponent("Cookies.binarycookies")

    /// Per-site totals for the "stays / goes" lists.
    private struct Site {
        var cookies = 0
        var bytes: Int64 = 0
    }

    static func scan(whitelist: Whitelist, testMode: Bool) -> Report {
        var report = Report(title: "Очистка cookies и данных сайтов", testMode: testMode)
        let website = SafariPaths.container.appendingPathComponent("WebKit/WebsiteData")
        var kept: [String: Site] = [:]
        var removed: [String: Site] = [:]

        // Cookies
        var cookieItem = Scanner.measure("Cookies Safari", cookieFile)
        if cookieItem.status == .found {
            let original = (try? Data(contentsOf: cookieFile)) ?? Data()
            if let file = BinaryCookies.parse(original) {
                report.facts.append("Cookies: \(file.cookieCount) шт. от \(file.domains.count) сайтов.")
                for (domain, count) in file.domains {
                    let host = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
                    if whitelist.contains(host: host) { kept[host, default: Site()].cookies += count }
                    else { removed[host, default: Site()].cookies += count }
                }
                if !kept.isEmpty {
                    // Some cookies stay: the file is rewritten instead of removed.
                    cookieItem.label = "Cookies Safari (файл остаётся, из него удаляются cookies не из белого списка)"
                    cookieItem.deletes = false
                    cookieItem.countsAsFreed = false
                    do {
                        let result = try CookieRewrite.run(original, whitelist: whitelist, testMode: testMode)
                        var gone = ScanItem(label: "Удаляемые cookies (\(result.removedCount) шт.)", url: cookieFile, deletes: false)
                        gone.status = .found
                        gone.bytes = Int64(original.count - result.data.count)
                        report.items.append(gone)
                    } catch {
                        report.facts.append("Cookies не тронуты: \(error.localizedDescription)")
                    }
                }
            } else if !whitelist.isEmpty {
                // Can't tell whose cookies are whose: removing the file would also log out of whitelisted sites.
                cookieItem.deletes = false
                cookieItem.countsAsFreed = false
                report.facts.append("Формат файла cookies не распознан, поэтому при включённом белом списке cookies не трогаются.")
            } else {
                report.facts.append("Формат файла cookies не распознан. Файл будет удалён целиком.")
            }
        }
        report.items.insert(cookieItem, at: 0)
        for url in Scanner.children(of: SafariPaths.cookies)
        where url.lastPathComponent.hasPrefix("Cookies.binarycookies_tmp_") {
            report.items.append(Scanner.measure("Старая временная копия cookies Safari (Safari её не использует)", url))
        }

        // Website data: one folder per site, named by a hash; the real name sits in an "origin" file.
        let siteRoot = website.appendingPathComponent("Default")
        var sites = Scanner.measure("Данные сайтов", siteRoot, contentsOnly: true)
        if sites.status == .found {
            var toDelete: [URL] = []
            var keptCount = 0
            var keptBytes: Int64 = 0
            for folder in Scanner.children(of: siteRoot) {
                let host = SiteData.name(of: folder) ?? "неизвестный сайт"
                let size = Scanner.measure("", folder)
                if whitelist.contains(host: host) {
                    kept[host, default: Site()].bytes += size.bytes
                    keptCount += 1
                    keptBytes += size.bytes
                } else {
                    removed[host, default: Site()].bytes += size.bytes
                    toDelete.append(folder)
                }
            }
            if keptCount > 0 {
                var stays = ScanItem(label: "Данные сайтов из белого списка (\(keptCount)), остаются", url: siteRoot,
                                     deletes: false, countsAsFreed: false)
                stays.status = .found
                stays.bytes = keptBytes
                report.items.append(stays)
                sites.only = toDelete
                sites.bytes -= keptBytes
                sites.files = toDelete.reduce(0) { $0 + Scanner.measure("", $1).files }
            }
            sites.label = "Данные сайтов (\(toDelete.count))"
        }
        report.items.append(sites)

        let more: [(String, URL)] = [
            ("Базы сайтов (IndexedDB)", website.appendingPathComponent("IndexedDB")),
            ("Локальное хранилище сайтов", website.appendingPathComponent("LocalStorage")),
            ("Старые базы сайтов (WebSQL)", website.appendingPathComponent("WebSQL")),
            ("Хранилище фоновых скриптов сайтов", SafariPaths.container.appendingPathComponent("Caches/WebKit/CacheStorage")),
            ("Старое место: локальное хранилище", SafariPaths.safari.appendingPathComponent("LocalStorage")),
            ("Старое место: базы сайтов", SafariPaths.safari.appendingPathComponent("Databases")),
        ]
        for (label, url) in more {
            report.items.append(Scanner.measure(label, url, contentsOnly: true))
        }
        report.items.removeAll { $0.status == .missing }

        // Stays / goes lists
        if whitelist.isEmpty {
            report.facts.append("Белый список пуст: будут удалены cookies и данные всех сайтов. Добавить сайты можно в меню «Белый список».")
        } else {
            report.facts.append("Белый список: " + whitelist.domains.joined(separator: ", ") + ".")
        }
        let stayVerb = testMode ? "Останутся" : "Остались"
        let goVerb = testMode ? "Будут удалены" : "Удалены"
        report.facts.append(kept.isEmpty
            ? "\(stayVerb): ни одного сайта."
            : "\(stayVerb) (\(kept.count)): " + describe(kept) + ".")
        if !removed.isEmpty {
            report.facts.append("\(goVerb) (\(removed.count)): " + describe(removed) + ".")
        }

        report.notes = [
            "Пароли хранятся отдельно (в «Связке ключей») и не удаляются, так что Safari сможет подставить их снова.",
            "Cookies других программ (Adobe, Музыка, TeamViewer и т. д.) лежат в той же папке и не трогаются.",
            "Не трогаем: HSTS (список защищённых сайтов), данные DRM для видео (MediaKeys), служебные данные защиты от слежки.",
            "Белый список действует по домену: google.com сохраняет и mail.google.com, и accounts.google.com. "
                + "Некоторые сервисы входят через несколько доменов: например, вход в Google использует ещё и youtube.com.",
            "Общие папки хранилищ (IndexedDB, LocalStorage, WebSQL, фоновые скрипты) не разделены по сайтам и очищаются целиком. Сейчас они почти пустые.",
        ]
        if !whitelist.isEmpty {
            report.notes.append("Перед изменением файла cookies делается резервная копия в ~/Library/Application Support/SafariCleaner. "
                                + "При ошибке она возвращается на место, после успешной очистки сразу удаляется.")
        }
        return report
    }

    private static func describe(_ sites: [String: Site]) -> String {
        sites.sorted { $0.key < $1.key }.map { host, site in
            var parts: [String] = []
            if site.cookies > 0 { parts.append("cookies: \(site.cookies)") }
            if site.bytes > 0 { parts.append("данные: \(Report.format(site.bytes))") }
            return parts.isEmpty ? host : "\(host) (\(parts.joined(separator: ", ")))"
        }.joined(separator: ", ")
    }
}

/// Keeps only whitelisted cookies. Every step is checked; the live file is touched only in real mode, under `Backup`.
enum CookieRewrite {
    struct Result {
        let data: Data
        let removedCount: Int
    }

    static func run(_ original: Data, whitelist: Whitelist, testMode: Bool) throws -> Result {
        guard let file = BinaryCookies.parse(original) else {
            throw CleanerError("формат файла cookies не распознан")
        }
        // If the file can't be rebuilt byte for byte, the format has something we don't understand.
        guard file.serialized() == original else {
            throw CleanerError("приложение не смогло точно воспроизвести файл cookies, менять его небезопасно")
        }
        let filtered = file.keeping { whitelist.contains(host: $0) }
        let data = filtered.serialized()
        guard let check = BinaryCookies.parse(data), check.cookieCount == filtered.cookieCount,
              check.serialized() == data else {
            throw CleanerError("проверка нового файла cookies не пройдена")
        }

        // Write and read back on a temporary copy first, in both modes.
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("SafariCleaner-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let copy = temp.appendingPathComponent("Cookies.binarycookies")
        try data.write(to: copy, options: .atomic)
        guard try Data(contentsOf: copy) == data else {
            throw CleanerError("проверка записи на временной копии не пройдена")
        }

        if !testMode {
            let live = CookiesCleaner.cookieFile
            try Backup.protect([live], named: "Cookies") {
                try data.write(to: live, options: .atomic)
                guard try Data(contentsOf: live) == data else {
                    throw CleanerError("записанный файл cookies не совпал с ожидаемым")
                }
            }
        }
        return Result(data: data, removedCount: file.cookieCount - filtered.cookieCount)
    }
}

/// Reader and writer for Safari's undocumented `Cookies.binarycookies` format. Every offset is bounds-checked.
///
/// Layout: "cook", page count and page sizes (big-endian), the pages, a checksum, then a trailer
/// (footer and Safari's cookie settings) that is kept as is. A page: 00 00 01 00, cookie count and
/// cookie offsets (little-endian), 00 00 00 00, then the cookie records.
enum BinaryCookies {
    struct Record {
        let domain: String
        let bytes: [UInt8]
    }

    struct File {
        var pages: [[Record]]
        /// Everything after the checksum.
        let trailer: [UInt8]

        var cookieCount: Int { pages.reduce(0) { $0 + $1.count } }

        /// Cookie count per domain, as written in the file (may start with a dot).
        var domains: [String: Int] {
            pages.joined().reduce(into: [:]) { $0[$1.domain, default: 0] += 1 }
        }

        func keeping(_ keep: (String) -> Bool) -> File {
            let kept = pages.map { page in page.filter { keep($0.domain) } }.filter { !$0.isEmpty }
            return File(pages: kept, trailer: trailer)
        }

        func serialized() -> Data {
            let pageBytes = pages.map(BinaryCookies.page)
            var out = Array("cook".utf8)
            out += be32(pageBytes.count)
            for page in pageBytes { out += be32(page.count) }
            var checksum: UInt32 = 0
            for page in pageBytes {
                out += page
                for i in stride(from: 0, to: page.count, by: 4) { checksum &+= UInt32(page[i]) }
            }
            out += be32(Int(checksum))
            out += trailer
            return Data(out)
        }
    }

    static func parse(_ data: Data) -> File? {
        let b = [UInt8](data)
        guard b.count >= 8, b[0..<4].elementsEqual("cook".utf8) else { return nil }
        let pageCount = Int(readBE32(b, 4))
        guard pageCount < b.count, 8 + pageCount * 4 <= b.count else { return nil }

        var pages: [[Record]] = []
        var pageStart = 8 + pageCount * 4
        for p in 0..<pageCount {
            let size = Int(readBE32(b, 8 + p * 4))
            guard size >= 12, pageStart + size <= b.count else { return nil }
            let page = Array(b[pageStart..<(pageStart + size)])
            guard page[0..<4].elementsEqual([0, 0, 1, 0]) else { return nil }
            let count = Int(readLE32(page, 4))
            guard 12 + count * 4 <= page.count else { return nil }
            var records: [Record] = []
            for c in 0..<count {
                let off = Int(readLE32(page, 8 + c * 4))
                guard off + 20 <= page.count else { return nil }
                let cookieSize = Int(readLE32(page, off))
                let urlOffset = Int(readLE32(page, off + 16))
                guard cookieSize >= 20, off + cookieSize <= page.count, urlOffset < cookieSize else { return nil }
                let domain = String(decoding: page[(off + urlOffset)..<(off + cookieSize)].prefix { $0 != 0 }, as: UTF8.self)
                records.append(Record(domain: domain, bytes: Array(page[off..<(off + cookieSize)])))
            }
            pages.append(records)
            pageStart += size
        }
        guard pageStart + 4 <= b.count else { return nil }
        return File(pages: pages, trailer: Array(b[(pageStart + 4)...]))
    }

    private static func page(_ records: [Record]) -> [UInt8] {
        var out: [UInt8] = [0, 0, 1, 0]
        out += le32(records.count)
        var offset = 8 + records.count * 4 + 4
        for record in records {
            out += le32(offset)
            offset += record.bytes.count
        }
        out += [0, 0, 0, 0]
        for record in records { out += record.bytes }
        return out
    }

    private static func readBE32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    private static func readLE32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i + 3]) << 24 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 1]) << 8 | UInt32(b[i])
    }

    private static func be32(_ v: Int) -> [UInt8] {
        let v = UInt32(truncatingIfNeeded: v)
        return [UInt8(v >> 24 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]
    }

    private static func le32(_ v: Int) -> [UInt8] {
        Array(be32(v).reversed())
    }
}

/// WebKit names each site's folder by a hash and stores the site name in an `origin` file:
/// length-prefixed strings (scheme, host, …), each with a 1-byte "Latin-1 vs UTF-16" flag.
enum SiteData {
    static func name(of siteFolder: URL) -> String? {
        for sub in Scanner.children(of: siteFolder) {
            guard let data = try? Data(contentsOf: sub.appendingPathComponent("origin")) else { continue }
            let b = [UInt8](data)
            var offset = 0
            func readString() -> String? {
                guard offset + 5 <= b.count else { return nil }
                let length = Int(UInt32(b[offset + 3]) << 24 | UInt32(b[offset + 2]) << 16
                    | UInt32(b[offset + 1]) << 8 | UInt32(b[offset]))
                let latin1 = b[offset + 4] == 1
                let byteCount = latin1 ? length : length * 2
                offset += 5
                guard byteCount >= 0, offset + byteCount <= b.count else { return nil }
                defer { offset += byteCount }
                return String(bytes: b[offset..<(offset + byteCount)], encoding: latin1 ? .isoLatin1 : .utf16LittleEndian)
            }
            guard readString() != nil, let host = readString(), !host.isEmpty else { continue }
            return host
        }
        return nil
    }
}
