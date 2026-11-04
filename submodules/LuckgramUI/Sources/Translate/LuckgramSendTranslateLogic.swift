import Foundation

/// specs#104: translate before sending, per chat. The 「中 → EN」 capsule text and the stored list of chats
/// with 「发送翻译」 on. Foundation only; unit-tested in `LuckgramSendTranslateLogicTests` (same labels as
/// Android `TranslateOutLogic.capsule`).
public enum LuckgramSendTranslateLogic {
    /// Base code: lower case, region dropped, every Chinese variant → zh; nil for empty / "und".
    public static func base(_ code: String?) -> String? {
        guard var value = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !value.isEmpty, value != "und" else {
            return nil
        }
        value = value.replacingOccurrences(of: "_", with: "-")
        if let dash = value.firstIndex(of: "-") {
            value = String(value[..<dash])
        }
        return value.isEmpty ? nil : value
    }

    /// 中, 日, 한 for CJK, else the base code upper-cased (EN, ES, PT).
    public static func shortLabel(_ code: String?) -> String {
        guard let b = base(code) else {
            return "?"
        }
        switch b {
        case "zh":
            return "中"
        case "ja":
            return "日"
        case "ko":
            return "한"
        default:
            return b.uppercased()
        }
    }

    /// 「EN → 日」; `from` is the language detected in what the user typed. Unknown (or the same as the
    /// target) → just 「→ 日」, never a guessed 「中」 (specs#110).
    public static func capsule(from: String?, to: String?) -> String {
        guard let f = base(from), f != base(to) else {
            return "→ " + shortLabel(to)
        }
        return shortLabel(from) + " → " + shortLabel(to)
    }

    /// The chats with 「发送翻译」 on, stored as "peerId,peerId,…".
    public static func decodeChats(_ stored: String?) -> [Int64] {
        guard let stored, !stored.isEmpty else {
            return []
        }
        var result: [Int64] = []
        for part in stored.split(separator: ",") {
            if let id = Int64(part.trimmingCharacters(in: .whitespaces)), !result.contains(id) {
                result.append(id)
            }
        }
        return result
    }

    public static func encodeChats(_ ids: [Int64]) -> String {
        var seen: [Int64] = []
        for id in ids where !seen.contains(id) {
            seen.append(id)
        }
        return seen.map { String($0) }.joined(separator: ",")
    }

    public static func updatingChats(_ stored: String?, peerId: Int64, on: Bool) -> String {
        var ids = decodeChats(stored).filter { $0 != peerId }
        if on {
            ids.append(peerId)
        }
        return encodeChats(ids)
    }
}
