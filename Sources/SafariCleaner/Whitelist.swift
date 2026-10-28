import Foundation

/// Sites whose cookies and website data are never removed. An entry covers its subdomains:
/// google.com keeps google.com, mail.google.com, accounts.google.com…
struct Whitelist: Sendable {
    let domains: [String]

    var isEmpty: Bool { domains.isEmpty }

    func contains(host: String) -> Bool {
        var host = host.lowercased()
        while host.hasPrefix(".") { host.removeFirst() }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// "https://www.Google.com/mail" → "google.com"; nil if the input doesn't look like a domain.
    static func normalize(_ input: String) -> String? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = s.range(of: "://") { s = String(s[scheme.upperBound...]) }
        s = String(s.prefix { !"/?#:".contains($0) })
        while s.hasPrefix(".") { s.removeFirst() }
        while s.hasSuffix(".") { s.removeLast() }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard s.contains("."), !s.contains(".."), s.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return s
    }
}

/// The list lives in the app's own folder, next to the temporary backups.
enum WhitelistStore {
    static let file = Backup.folder.appendingPathComponent("whitelist.json")

    static func load() -> [String] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    static func save(_ domains: [String]) throws {
        try FileManager.default.createDirectory(at: Backup.folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(domains).write(to: file, options: .atomic)
    }
}
