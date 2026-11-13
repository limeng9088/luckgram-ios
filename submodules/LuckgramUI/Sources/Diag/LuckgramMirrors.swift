import Foundation

/// specs#160: luckgram.cc, wiki, dl and web (the web version) are blocked by name on some networks while cat158.com is
/// not, so each has a backup host with the same content (Info.plist `LuckgramSiteMirrors`, next to
/// the API entries of specs#81). While the API is on a backup entry (that network blocks
/// luckgram.cc), website / help center links and the package download open on the backup host.
/// iOS downloads the IPA in the browser, so unlike Android there is no in-app retry: the backup
/// entry is the signal. Foundation only, unit tested on Linux; same rules as Android `LuckgramMirrors`.
public struct LuckgramMirrors: Equatable {
    /// host (lower case) -> backup host.
    public let hosts: [String: String]

    public init(hosts: [String: String]) {
        self.hosts = hosts
    }

    /// `["luckgram.cc": "lg-www.cat158.com", ...]` from Info.plist; entries that are not two host
    /// names are skipped.
    public static func parse(_ value: [String: Any]?) -> LuckgramMirrors {
        var out: [String: String] = [:]
        for (key, raw) in value ?? [:] {
            guard let target = raw as? String else {
                continue
            }
            let from = key.trimmingCharacters(in: .whitespaces).lowercased()
            let to = target.trimmingCharacters(in: .whitespaces).lowercased()
            if isHost(from) && isHost(to) && from != to {
                out[from] = to
            }
        }
        return LuckgramMirrors(hosts: out)
    }

    static func isHost(_ h: String) -> Bool {
        return h.range(of: "^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", options: .regularExpression) != nil
    }

    /// `url` on its backup host (path, query and fragment kept), or nil when it is not an https URL
    /// on one of the mirrored hosts. URLs with user info or a port are left alone.
    public func mirror(_ url: String) -> String? {
        guard url.lowercased().hasPrefix("https://") else {
            return nil
        }
        let rest = url.dropFirst(8)
        let end = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
        var host = String(rest[rest.startIndex..<end]).lowercased()
        if host.contains("@") || host.contains(":") {
            return nil
        }
        if host.hasSuffix(".") {
            host.removeLast()
        }
        guard let to = self.hosts[host] else {
            return nil
        }
        return "https://" + to + String(rest[end...])
    }

    /// Link to open: the backup host while the API uses a backup entry.
    public func forSite(_ url: String, apiOnBackup: Bool) -> String {
        guard apiOnBackup else {
            return url
        }
        return self.mirror(url) ?? url
    }
}
