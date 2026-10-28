import Foundation

/// Button 1: only regenerable caches. Never CloudKit (iCloud sync state) or HSTS (security list).
enum CacheCleaner {
    private static let names: [String: String] = [
        "Cache.db": "База кэша страниц",
        "Cache.db-shm": "Служебный файл базы кэша",
        "Cache.db-wal": "Служебный файл базы кэша",
        "fsCachedData": "Кэшированные файлы сайтов",
        "WebKitCache": "Кэш движка WebKit",
        "TabSnapshots": "Снимки-превью вкладок (сами вкладки не трогаются)",
        "Webpage Previews": "Превью страниц",
        "Bookmarks Sidebar Thumbnails": "Миниатюры в панели закладок (сами закладки не трогаются)",
        "com.apple.e5rt.e5bundlecache": "Кэш встроенных ML-моделей Safari",
    ]

    static func scan() -> Report {
        var report = Report(title: "Очистка кэша")

        for url in Scanner.children(of: SafariPaths.container.appendingPathComponent("Caches/com.apple.Safari")) {
            let name = url.lastPathComponent
            report.items.append(Scanner.measure(names[name] ?? "Кэш Safari: \(name)", url))
        }
        report.items.append(Scanner.measure(
            "Сетевой кэш WebKit",
            SafariPaths.container.appendingPathComponent("Caches/WebKit/NetworkCache"),
            contentsOnly: true))

        let legacy = SafariPaths.library.appendingPathComponent("Caches/com.apple.Safari")
        for name in ["Cache.db", "Cache.db-shm", "Cache.db-wal", "fsCachedData", "WebKitCache"] {
            report.items.append(Scanner.measure("Старое место: \(names[name] ?? name)", legacy.appendingPathComponent(name)))
        }

        report.items.removeAll { $0.status == .missing }
        report.notes = [
            "Не трогаем: CloudKit (служебные данные синхронизации iCloud), HSTS (список сайтов, которые обязаны открываться только по защищённому соединению), картинку профиля iCloud.",
            "Кэш безопасно удалять: Safari заново скачает нужное при следующем открытии сайтов. Первые загрузки могут быть чуть медленнее.",
        ]
        return report
    }
}
