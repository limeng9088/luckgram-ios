import Foundation

/// Luckgram 32: cloud backup wire format (S15 `/v1/backup`) and the weekly auto-backup rule.
/// The server only sees the encrypted 10 backup file (base64) plus a few counters; the password
/// never leaves the device. Same rules as Android `CloudBackupLogic`. Foundation only, unit tested.
public enum LuckgramCloudBackupLogic {
    public static let path = "/v1/backup"
    public static let formatVersion = 1
    public static let autoInterval: TimeInterval = 7 * 24 * 60 * 60

    public struct Meta: Equatable {
        public let accounts: Int
        /// Seconds since 1970; 0 when unknown.
        public let createdAt: TimeInterval
        /// Base64 of the encrypted file; nil when the response only carries metadata.
        public let data: String?

        public init(accounts: Int, createdAt: TimeInterval, data: String?) {
            self.accounts = accounts
            self.createdAt = createdAt
            self.data = data
        }
    }

    /// `PUT /v1/backup` body; `dataBase64` is the encrypted backup file.
    public static func uploadBody(dataBase64: String, accounts: Int, createdAt: TimeInterval) -> [String: Any] {
        return [
            "data": dataBase64,
            "accounts": accounts,
            "created_at": rfc3339(createdAt),
            "format_version": formatVersion
        ]
    }

    /// Parses `{"backup":{...}}` (or the bare object); nil when there is no backup.
    public static func parseMeta(_ response: [String: Any]?) -> Meta? {
        guard let response else {
            return nil
        }
        let backup: [String: Any]
        if let value = response["backup"] as? [String: Any] {
            backup = value
        } else if response["backup"] == nil, response["accounts"] != nil {
            backup = response
        } else {
            return nil
        }
        let accounts = (backup["accounts"] as? Int) ?? (backup["accounts"] as? NSNumber)?.intValue ?? 0
        let created = (backup["created_at"] as? String) ?? (backup["uploaded_at"] as? String) ?? ""
        let data = backup["data"] as? String
        return Meta(accounts: max(0, accounts), createdAt: parseRFC3339(created), data: (data?.isEmpty ?? true) ? nil : data)
    }

    /// "No backup yet" from `GET /v1/backup`.
    public static func isNotFound(code: String, httpStatus: Int) -> Bool {
        return httpStatus == 404 || code == "not_found"
    }

    /// Weekly auto backup: due when it is on, the password is remembered and 7 days have passed.
    public static func autoBackupDue(enabled: Bool, passwordRemembered: Bool, last: TimeInterval, now: TimeInterval) -> Bool {
        if !enabled || !passwordRemembered {
            return false
        }
        return last <= 0 || now - last >= autoInterval || now < last
    }

    public static func rfc3339(_ time: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter.string(from: Date(timeIntervalSince1970: time))
    }

    public static func parseRFC3339(_ value: String) -> TimeInterval {
        if value.isEmpty {
            return 0
        }
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: value) {
                return date.timeIntervalSince1970
            }
        }
        return 0
    }
}
