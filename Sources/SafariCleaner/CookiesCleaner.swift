import Foundation

/// Button 2: Safari's cookies plus website data (local storage, site databases, service workers).
enum CookiesCleaner {
    static func scan() -> Report {
        var report = Report(title: "Очистка cookies и данных сайтов")
        let website = SafariPaths.container.appendingPathComponent("WebKit/WebsiteData")

        // Cookies
        let cookieFile = SafariPaths.cookies.appendingPathComponent("Cookies.binarycookies")
        let cookieItem = Scanner.measure("Cookies Safari", cookieFile)
        report.items.append(cookieItem)
        if cookieItem.status == .found {
            if let data = try? Data(contentsOf: cookieFile), let domains = BinaryCookies.domains(in: data) {
                let total = domains.values.reduce(0, +)
                report.facts.append("Cookies: \(total) шт. от \(domains.count) сайтов.")
                let top = domains.sorted { $0.value > $1.value }.prefix(10).map { "\($0.key) (\($0.value))" }
                if !top.isEmpty { report.facts.append("Больше всего cookies у: " + top.joined(separator: ", ") + ".") }
            } else {
                report.facts.append("Файл cookies найден, но его формат не распознан. Количество сайтов посчитать не удалось.")
            }
        }
        for url in Scanner.children(of: SafariPaths.cookies)
        where url.lastPathComponent.hasPrefix("Cookies.binarycookies_tmp_") {
            report.items.append(Scanner.measure("Старая временная копия cookies Safari", url))
        }

        // Website data: one folder per site, named by a hash; the real name sits in an "origin" file.
        var sites = Scanner.measure("Данные сайтов", website.appendingPathComponent("Default"), contentsOnly: true)
        let siteFolders = Scanner.children(of: sites.url)
        if sites.status == .found {
            let sized = siteFolders.map { (SiteData.name(of: $0) ?? "неизвестный сайт", Scanner.measure("", $0).bytes) }
            sites = ScanItem(label: "Данные сайтов (\(siteFolders.count) сайтов)", url: sites.url, contentsOnly: true,
                             status: sites.status, files: sites.files, bytes: sites.bytes)
            let top = sized.sorted { $0.1 > $1.1 }.prefix(10).map { "\($0.0) (\(Report.format($0.1)))" }
            if !top.isEmpty { report.facts.append("Больше всего данных хранят: " + top.joined(separator: ", ") + ".") }
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
        report.notes = [
            "После очистки вы выйдете из аккаунтов на большинстве сайтов. Пароли хранятся отдельно (в «Связке ключей») и не удаляются, так что Safari сможет подставить их снова.",
            "Cookies других программ (Adobe, Музыка, TeamViewer и т. д.) лежат в той же папке и не трогаются.",
            "Не трогаем: HSTS (список защищённых сайтов), данные DRM для видео (MediaKeys), служебные данные защиты от слежки.",
            "Белый список сайтов, которые не нужно чистить, добавим на этапе 3.",
        ]
        return report
    }
}

/// Reader for Safari's undocumented `Cookies.binarycookies` format. Read-only; every offset is bounds-checked.
enum BinaryCookies {
    /// Cookie count per domain, or nil if the file doesn't look like Safari's cookie format.
    static func domains(in data: Data) -> [String: Int]? {
        let b = [UInt8](data)
        guard b.count >= 8, b[0..<4].elementsEqual("cook".utf8) else { return nil }
        let pageCount = Int(be32(b, 4))
        guard pageCount < b.count, 8 + pageCount * 4 <= b.count else { return nil }

        var result: [String: Int] = [:]
        var pageStart = 8 + pageCount * 4
        for p in 0..<pageCount {
            let size = Int(be32(b, 8 + p * 4))
            guard size >= 8, pageStart + size <= b.count else { return nil }
            let page = Array(b[pageStart..<(pageStart + size)])
            guard page[0..<4].elementsEqual([0, 0, 1, 0]) else { return nil }
            let count = Int(le32(page, 4))
            guard 8 + count * 4 <= page.count else { return nil }
            for c in 0..<count {
                let off = Int(le32(page, 8 + c * 4))
                guard off + 20 <= page.count else { return nil }
                let cookieSize = Int(le32(page, off))
                let urlOffset = Int(le32(page, off + 16))
                guard cookieSize >= 20, off + cookieSize <= page.count, urlOffset < cookieSize else { return nil }
                var domain = String(decoding: page[(off + urlOffset)..<(off + cookieSize)].prefix { $0 != 0 }, as: UTF8.self)
                if domain.hasPrefix(".") { domain.removeFirst() }
                result[domain, default: 0] += 1
            }
            pageStart += size
        }
        return result
    }

    private static func be32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }

    private static func le32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i + 3]) << 24 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 1]) << 8 | UInt32(b[i])
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
