import Foundation

/// luckgram-ios#145: the `?script=` sent with /v1/ai/transcribe, so a Chinese transcript comes back
/// in the script of the current UI (the server converts; without it the registration locale wins).
/// Same rule as `LuckgramStrings.isChinese`: the Telegram UI language first, then the system
/// language. Same as Android `LuckgramChineseScript`.
///
/// Pure (Foundation only) so it is unit tested on its own.
public enum LuckgramChineseScript {
    /// "Hans" / "Hant" for a Chinese language code ("zh-hans-beta", "zh-hant-beta", "zh-Hant-TW",
    /// "zh_TW", "classic-zh-cn", "taiwan", …), nil for any other language.
    public static func of(_ code: String?) -> String? {
        guard let code = code?.lowercased().replacingOccurrences(of: "_", with: "-"), !code.isEmpty else {
            return nil
        }
        let tokens = code.split(separator: "-").map(String.init)
        let chinese = code.hasPrefix("zh") || tokens.contains("zh") || tokens.contains("taiwan")
        guard chinese else {
            return nil
        }
        let traditional = tokens.contains(where: { $0.hasPrefix("hant") || ["tw", "hk", "mo", "taiwan"].contains($0) })
        return traditional ? "Hant" : "Hans"
    }

    /// The UI language's script when it is Chinese, else the system language's, else nil.
    public static func pick(appLanguageCode: String?, systemLanguage: String?) -> String? {
        return of(appLanguageCode) ?? of(systemLanguage)
    }
}
