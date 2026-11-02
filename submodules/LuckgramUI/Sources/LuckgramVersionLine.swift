import Foundation

/// Luckgram 28: the version line at the bottom of Settings, identical on iOS and Android:
/// `Luckgram 13.1.1 (36067) · 19e5f52`.
public enum LuckgramVersionLine {
    public static let unknown = "unknown"
    /// Info.plist key written at build time (build-system/Make/BuildConfiguration + build.yml).
    public static let gitCommitInfoKey = "LuckgramGitCommit"

    public static func format(version: String?, build: String?, commit: String?) -> String {
        let versionText = trimmed(version) ?? unknown
        let buildText = trimmed(build) ?? unknown
        return "Luckgram \(versionText) (\(buildText)) \u{00B7} \(shortCommit(commit))"
    }

    public static func shortCommit(_ commit: String?) -> String {
        guard let value = trimmed(commit)?.lowercased(), (7 ... 40).contains(value.count), value.allSatisfy({ $0.isHexDigit }) else {
            return unknown
        }
        return String(value.prefix(7))
    }

    public static func current(bundle: Bundle = .main) -> String {
        let info = bundle.infoDictionary ?? [:]
        return format(
            version: info["CFBundleShortVersionString"] as? String,
            build: info["CFBundleVersion"] as? String,
            commit: info[gitCommitInfoKey] as? String
        )
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }
}
