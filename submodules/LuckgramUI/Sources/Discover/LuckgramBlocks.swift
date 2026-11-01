import Foundation
import SwiftSignalKit
import LuckgramDiscover

/// Client for the block list shared by People Nearby (25) and Square (26): `POST /v1/blocks`,
/// `DELETE /v1/blocks/{user}`, `GET /v1/blocks`. Use these instead of calling the endpoints
/// directly so the local name cache (for the blocked people page) stays in sync.
public enum LuckgramBlocks {
    private static let namesKey = "luckgram.blocks.names"

    public static var texts: BlockLogic.Texts {
        return BlockLogic.Texts(zh: LuckgramStrings.isChinese)
    }

    /// Blocks `userId`; `displayName` is remembered locally for the blocked list.
    public static func block(userId: String, displayName: String?) -> Signal<Void, LuckgramAIError> {
        return LuckgramAI.shared.requestJSON(method: "POST", path: BlockLogic.path, body: BlockLogic.blockBody(userId))
        |> map { _ -> Void in
            setNames(BlockLogic.putName(names(), id: userId, name: displayName))
            return Void()
        }
    }

    public static func unblock(userId: String) -> Signal<Void, LuckgramAIError> {
        return LuckgramAI.shared.requestJSON(method: "DELETE", path: BlockLogic.deletePath(userId))
        |> map { _ -> Void in
            setNames(BlockLogic.putName(names(), id: userId, name: nil))
            return Void()
        }
    }

    public static func list(cursor: String?) -> Signal<(ids: [String], nextCursor: String?), LuckgramAIError> {
        return LuckgramAI.shared.requestJSON(method: "GET", path: BlockLogic.listPath(cursor: cursor))
        |> map { json in
            return (BlockLogic.parseIds(json), BlockLogic.nextCursor(json))
        }
    }

    /// Name seen when blocking, or nil if this device doesn't know it.
    public static func name(of userId: String) -> String? {
        return names()[userId]
    }

    /// Logout / unlink: the list belongs to the linked user, forget the cached names.
    public static func clearLocal() {
        UserDefaults.standard.removeObject(forKey: namesKey)
    }

    private static func names() -> [String: String] {
        return (UserDefaults.standard.dictionary(forKey: namesKey) as? [String: String]) ?? [:]
    }

    private static func setNames(_ names: [String: String]) {
        UserDefaults.standard.set(names, forKey: namesKey)
    }
}
