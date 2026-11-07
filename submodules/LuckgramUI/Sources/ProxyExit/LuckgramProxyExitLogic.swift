import Foundation

/// specs#117: the exit (public IP + country) the Luckgram server sees for a request sent directly
/// or through one proxy — the answer of `GET /v1/net/whoami` (specs#116).
///
/// Foundation only, unit-tested in `LuckgramProxyExitLogicTests`. Same format as Android `ExitInfo`.
public struct LuckgramProxyExit: Equatable {
    public static let path = "/v1/net/whoami"
    /// Results are kept this long; the same proxy is not asked again within it.
    public static let ttl: TimeInterval = 10 * 60

    public let ip: String
    /// ISO 3166-1 alpha-2, upper case, or "" when unknown.
    public let country: String
    public let city: String

    public init(ip: String, country: String, city: String) {
        self.ip = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        let cc = country.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let letters = cc.unicodeScalars.allSatisfy { $0.value >= 65 && $0.value <= 90 }
        self.country = (cc.count == 2 && letters && cc != "XX" && cc != "T1") ? cc : ""
        self.city = city.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parses the whoami JSON; nil when it has no usable IP.
    public static func parse(_ data: Data) -> LuckgramProxyExit? {
        guard let object = try? JSONSerialization.jsonObject(with: data), let dict = object as? [String: Any] else {
            return nil
        }
        let exit = LuckgramProxyExit(ip: dict["ip"] as? String ?? "", country: dict["country"] as? String ?? "", city: dict["city"] as? String ?? "")
        return exit.ip.isEmpty ? nil : exit
    }

    /// Regional-indicator flag for a two-letter upper-case code, "" otherwise.
    public static func flag(_ cc: String) -> String {
        let scalars = Array(cc.unicodeScalars)
        guard scalars.count == 2, scalars.allSatisfy({ $0.value >= 65 && $0.value <= 90 }) else {
            return ""
        }
        var out = ""
        for s in scalars {
            if let f = Unicode.Scalar(0x1F1E6 + s.value - 65) {
                out.unicodeScalars.append(f)
            }
        }
        return out
    }

    /// "🇸🇬 新加坡 · 45.39.75.124", or just the IP when the country is unknown.
    /// `countryName` maps a code to a display name (falls back to the code when it returns nil).
    public func label(countryName: (String) -> String?) -> String {
        if country.isEmpty {
            return ip
        }
        let name = countryName(country) ?? country
        return "\(LuckgramProxyExit.flag(country)) \(name.isEmpty ? country : name) · \(ip)"
    }

    public static func isFresh(checkedAt: Date?, now: Date) -> Bool {
        guard let checkedAt = checkedAt else {
            return false
        }
        let age = now.timeIntervalSince(checkedAt)
        return age >= 0 && age < ttl
    }
}

/// Texts of the exit lines (Chinese or English, the Luckgram language rule).
public struct LuckgramProxyExitTexts {
    public let zh: Bool

    public init(zh: Bool) {
        self.zh = zh
    }

    public var directTitle: String { zh ? "直连（不使用代理）" : "Direct (no proxy)" }
    public var exitPrefix: String { zh ? "出口：" : "Exit: " }
    public var checking: String { zh ? "正在检测出口…" : "Checking exit…" }
    public var failed: String { zh ? "出口检测失败" : "Exit check failed" }

    public func countryName(_ cc: String) -> String? {
        return Locale(identifier: zh ? "zh-Hans" : "en").localizedString(forRegionCode: cc)
    }

    public func line(for exit: LuckgramProxyExit) -> String {
        return exitPrefix + exit.label(countryName: { self.countryName($0) })
    }
}
