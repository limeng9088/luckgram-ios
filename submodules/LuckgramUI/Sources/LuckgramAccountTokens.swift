import Foundation

/// specs#209: every server identity (AI credits, Pro, Square, People Nearby, backup) follows the
/// Telegram user the device token is linked to, so each logged-in Telegram account has its own
/// device token and link state (same as `AccountTokens` on Android). Pure rules, unit tested.
public enum LuckgramAccountTokens {
    /// Keychain account of the single token of older versions; now the token used while no
    /// account is logged in.
    public static let legacyAccount = "device_token"
    /// Keychain account listing the users that have a token, so reset and a fresh install can
    /// remove them all.
    public static let usersAccount = "device_token_users"
    /// Settings key: set once the legacy token was handed to an account, or kept.
    public static let migratedKey = "_device_token_migrated"

    /// Keychain account of the device token for Telegram user `user`; 0 = no account.
    public static func account(user: Int64) -> String {
        return user == 0 ? legacyAccount : "\(legacyAccount).u\(user)"
    }

    /// The stored user list, e.g. "12,34".
    public static func decodeUsers(_ value: String?) -> [Int64] {
        guard let value else {
            return []
        }
        var result: [Int64] = []
        for part in value.split(separator: ",") {
            if let user = Int64(part.trimmingCharacters(in: .whitespaces)), user != 0, !result.contains(user) {
                result.append(user)
            }
        }
        return result
    }

    public static func encodeUsers(_ users: [Int64]) -> String {
        var seen: [Int64] = []
        for user in users where user != 0 && !seen.contains(user) {
            seen.append(user)
        }
        return seen.map { String($0) }.joined(separator: ",")
    }

    /// Who gets the legacy token on upgrade. It is linked to one unknown Telegram user (the server
    /// does not tell), so it goes to `user` only when that is the one account logged in. With
    /// several accounts each registers its own token and links itself on first use, never acting
    /// as another account.
    public static func adoptsLegacy(user: Int64, loggedIn: [Int64]) -> Bool {
        return user != 0 && loggedIn.count == 1 && loggedIn[0] == user
    }
}
