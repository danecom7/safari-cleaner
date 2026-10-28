import Foundation

/// The only places on disk the app may look at (and, from stage 2, delete in),
/// plus a guard that refuses everything else.
enum SafariPaths {
    static let library = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library", isDirectory: true)
    /// Safari's sandbox container.
    static let container = library.appendingPathComponent("Containers/com.apple.Safari/Data/Library", isDirectory: true)
    /// Safari's own folder: history and favicons live here (bookmarks too, but those are never touched).
    static let safari = library.appendingPathComponent("Safari", isDirectory: true)
    /// Shared cookie folder. Safari's container links here; other apps keep their cookies here too.
    static let cookies = library.appendingPathComponent("Cookies", isDirectory: true)

    static let allowedRoots: [URL] = [
        container.appendingPathComponent("Caches/com.apple.Safari"),
        container.appendingPathComponent("Caches/WebKit"),
        container.appendingPathComponent("WebKit/WebsiteData"),
        library.appendingPathComponent("Caches/com.apple.Safari"),
        cookies,
        safari,
    ]

    /// Name prefixes that are never touched, even inside an allowed root.
    static let forbiddenPrefixes = [
        "Bookmarks", "SafariTabs", "CloudTabs", "RecentlyClosedTabs", "LastSession", "TopSites",
        "Form Values", "Password", "HSTS", "CloudKit", "Extensions", "WebExtensions", "AppExtensions",
    ]

    static func isAllowed(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        let path = standardized.path
        // No symlinks anywhere on the way: a link could point outside Safari's folders.
        guard standardized.resolvingSymlinksInPath().path == path else { return false }
        // Only components below the user's home are checked: the home path itself is not ours to judge.
        let inside = standardized.pathComponents.dropFirst(SafariPaths.library.pathComponents.count)
        guard !inside.contains(where: { component in
            forbiddenPrefixes.contains { component.hasPrefix($0) }
        }) else { return false }
        // In the shared cookie folder only Safari's own cookie files are ours.
        if standardized.deletingLastPathComponent().path == cookies.path {
            return standardized.lastPathComponent.hasPrefix("Cookies.binarycookies")
        }
        return allowedRoots.contains { path.hasPrefix($0.standardizedFileURL.path + "/") }
    }

    /// Without Full Disk Access macOS hides Safari's folders from every app.
    static func hasFullDiskAccess() -> Bool {
        let fm = FileManager.default
        return (try? fm.contentsOfDirectory(atPath: safari.path)) != nil
            && (try? fm.contentsOfDirectory(atPath: container.path)) != nil
    }
}

/// One file or folder and how much it weighs.
struct ScanItem: Identifiable, Sendable {
    enum Status: Sendable { case found, missing, noAccess, refused }

    let id = UUID()
    let label: String
    let url: URL
    /// The folder itself stays, only what's inside goes.
    var contentsOnly = false
    /// False for files that are edited rather than removed (History.db) and for computed rows.
    var deletes = true
    /// False when the size is shown for information only and isn't "freed".
    var countsAsFreed = true
    var status: Status = .missing
    var files = 0
    var bytes: Int64 = 0
}

enum Scanner {
    private static let keys: Set<URLResourceKey> = [
        .isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .totalFileAllocatedSizeKey, .fileResourceIdentifierKey,
    ]

    /// Measures a file or a whole folder without changing anything. Symlinks are never followed.
    static func measure(_ label: String, _ url: URL, contentsOnly: Bool = false,
                        deletes: Bool = true, countsAsFreed: Bool = true) -> ScanItem {
        var item = ScanItem(label: label, url: url, contentsOnly: contentsOnly, deletes: deletes, countsAsFreed: countsAsFreed)
        guard SafariPaths.isAllowed(url) else {
            item.status = .refused
            return item
        }
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: keys)
        } catch {
            let code = (error as NSError).code
            item.status = (code == NSFileReadNoSuchFileError || code == NSFileNoSuchFileError) ? .missing : .noAccess
            return item
        }
        if values.isSymbolicLink == true {
            item.status = .refused
            return item
        }
        item.status = .found
        guard values.isDirectory == true else {
            item.files = 1
            item.bytes = Int64(values.totalFileAllocatedSize ?? 0)
            return item
        }
        var failed = false
        // WebKit's cache hard-links identical files; each one takes disk space only once.
        var seen = Set<AnyHashable>()
        let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: [],
            errorHandler: { _, _ in failed = true; return true })
        while let file = enumerator?.nextObject() as? URL {
            guard let v = try? file.resourceValues(forKeys: keys),
                  v.isRegularFile == true, v.isSymbolicLink != true else { continue }
            if let identifier = v.fileResourceIdentifier as? AnyHashable, !seen.insert(identifier).inserted { continue }
            item.files += 1
            item.bytes += Int64(v.totalFileAllocatedSize ?? 0)
        }
        if failed || enumerator == nil { item.status = .noAccess }
        return item
    }

    static func children(of url: URL) -> [URL] {
        let list = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return list.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
