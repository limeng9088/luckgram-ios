// Luckgram — keyword folders.
// Local, per-account chat folders whose content is "chats whose recent messages mention a keyword".
// They are never synced: they live in this account's local preferences and are merged into the
// folder list only where the chat list UI reads it (tabs, the list itself). Every write path to
// Telegram's cloud folders (updateChatListFiltersInteractively) ignores ids it does not know.

import Foundation
import UIKit
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import AccountContext
import LuckgramUI

/// Cloud folder ids are 2...255; keyword folders use ids from here up.
public let keywordFolderFilterIdBase: Int32 = 1_000_000
public let keywordFoldersMaxCount: Int = 10
public let keywordFoldersMaxKeywords: Int = 10
/// How many cached messages per chat are checked besides the last one.
public let keywordFoldersRecentMessageLimit: Int = 50
/// How many cached messages are checked when jumping between hits inside a chat.
public let keywordFoldersJumpMessageLimit: Int = 500
private let keywordFoldersMaxScannedChats: Int = 1000

public func isKeywordFolderFilterId(_ id: Int32?) -> Bool {
    guard let id else {
        return false
    }
    return id >= keywordFolderFilterIdBase
}

// MARK: - Feature switch

/// Feature switch `keyword_folders` (registered in `LuckgramFeatures`, default on). Read through
/// `LuckgramSettings`, so both the local switch and the S4 remote config apply (#43, #54).
public enum KeywordFoldersSettings {
    public static let key = "keyword_folders"

    public static var isEnabled: Bool {
        return LuckgramSettings.shared.isEnabled(key)
    }

    public static func setEnabled(_ value: Bool) {
        LuckgramSettings.shared.setEnabled(key, value)
    }

    /// Current value, then every change (settings page or remote config). Main queue.
    public static var enabledSignal: Signal<Bool, NoError> {
        return LuckgramSettings.shared.isEnabledSignal(key)
    }
}

// MARK: - Model

public struct KeywordFolder: Codable, Equatable {
    public static let scopePrivate: Int32 = 1
    public static let scopeGroups: Int32 = 2
    public static let scopeChannels: Int32 = 4
    public static let scopeAll: Int32 = 7

    public var id: Int32
    public var name: String
    public var keywords: [String]
    public var scope: Int32
    /// Index in the folder tab bar (including "All Chats"); Int32.max appends.
    public var position: Int32

    public init(id: Int32, name: String, keywords: [String], scope: Int32, position: Int32) {
        self.id = id
        self.name = name
        self.keywords = keywords
        self.scope = scope
        self.position = position
    }

    public var filterId: Int32 {
        return keywordFolderFilterIdBase + self.id
    }

    func includes(peer: EnginePeer) -> Bool {
        if self.scope & KeywordFolder.scopeAll == KeywordFolder.scopeAll {
            return true
        }
        if case .user = peer {
            return self.scope & KeywordFolder.scopePrivate != 0
        }
        if case .secretChat = peer {
            return self.scope & KeywordFolder.scopePrivate != 0
        }
        if case let .channel(channel) = peer, case .broadcast = channel.info {
            return self.scope & KeywordFolder.scopeChannels != 0
        }
        return self.scope & KeywordFolder.scopeGroups != 0
    }
}

private struct KeywordFoldersStorage: Codable {
    var folders: [KeywordFolder]
}

/// Stored in this account's local preferences (deleted with the account on log out, never synced).
private let keywordFoldersPreferencesKey: EngineDataBuffer = applicationSpecificPreferencesKey(106)

private func decodeKeywordFolders(_ data: Data?) -> [KeywordFolder] {
    guard let data, let storage = try? JSONDecoder().decode(KeywordFoldersStorage.self, from: data) else {
        return []
    }
    return storage.folders
}

private let keywordFolderCache = Atomic<[EnginePeer.Id: [KeywordFolder]]>(value: [:])

/// Last known folders of an account, for synchronous lookups from list item construction.
public func cachedKeywordFolder(accountPeerId: EnginePeer.Id, filterId: Int32?) -> KeywordFolder? {
    guard let filterId, isKeywordFolderFilterId(filterId), KeywordFoldersSettings.isEnabled else {
        return nil
    }
    return keywordFolderCache.with { $0[accountPeerId] }?.first(where: { $0.filterId == filterId })
}

public func keywordFolders(context: AccountContext) -> Signal<[KeywordFolder], NoError> {
    let accountPeerId = context.account.peerId
    return context.engine.data.subscribe(TelegramEngine.EngineData.Item.Configuration.ApplicationSpecificPreference(key: keywordFoldersPreferencesKey))
    |> map { entry -> [KeywordFolder] in
        let folders = decodeKeywordFolders(entry?.data)
        let _ = keywordFolderCache.modify { current in
            var current = current
            current[accountPeerId] = folders
            return current
        }
        return folders
    }
    |> distinctUntilChanged
}

public func updateKeywordFolders(context: AccountContext, _ f: @escaping ([KeywordFolder]) -> [KeywordFolder]) -> Signal<Never, NoError> {
    return context.engine.preferences.update(id: keywordFoldersPreferencesKey, { entry in
        let updated = f(decodeKeywordFolders(entry?.data))
        guard let data = try? JSONEncoder().encode(KeywordFoldersStorage(folders: updated)) else {
            return entry
        }
        return SharedPreferencesEntry(data: data)
    })
}

/// Saves where the user dragged keyword folders in the tab bar. `orderedIds` uses 0 for "All Chats".
public func saveKeywordFolderPositions(context: AccountContext, orderedIds: [Int32]) -> Signal<Never, NoError> {
    return updateKeywordFolders(context: context, { folders in
        return folders.map { folder in
            var folder = folder
            if let index = orderedIds.firstIndex(of: folder.filterId) {
                folder.position = Int32(index)
            }
            return folder
        }
    })
}

// MARK: - Matching

private func isCjk(_ c: unichar) -> Bool {
    return (c >= 0x2E80 && c <= 0x9FFF) || (c >= 0xAC00 && c <= 0xD7AF) || (c >= 0xF900 && c <= 0xFAFF) || (c >= 0xFF00 && c <= 0xFFEF)
}

private func isWordChar(_ c: unichar) -> Bool {
    if isCjk(c) {
        return false
    }
    if c == 0x5F {
        return true
    }
    guard let scalar = Unicode.Scalar(c) else {
        return true // surrogate halves: treat as letters, never as a boundary
    }
    return CharacterSet.alphanumerics.contains(scalar)
}

/// Every occurrence of every keyword. Case-insensitive; keywords containing CJK characters match as
/// substrings, others only as whole words ("invoice" matches "Invoice #12" but not "invoices").
public func keywordFolderRanges(in text: String, keywords: [String]) -> [(NSRange, String)] {
    if text.isEmpty || keywords.isEmpty {
        return []
    }
    let string = text as NSString
    let length = min(string.length, 8192)
    var result: [(NSRange, String)] = []
    for keyword in keywords {
        let keywordString = keyword as NSString
        let keywordLength = keywordString.length
        if keywordLength == 0 || keywordLength > length {
            continue
        }
        var substring = false
        for i in 0 ..< keywordLength {
            if isCjk(keywordString.character(at: i)) {
                substring = true
                break
            }
        }
        let checkStart = isWordChar(keywordString.character(at: 0))
        let checkEnd = isWordChar(keywordString.character(at: keywordLength - 1))
        var searchRange = NSRange(location: 0, length: length)
        while searchRange.length > 0 {
            let found = string.range(of: keyword, options: [.caseInsensitive], range: searchRange)
            if found.location == NSNotFound {
                break
            }
            var accepted = true
            if !substring {
                if checkStart && found.location > 0 && isWordChar(string.character(at: found.location - 1)) {
                    accepted = false
                }
                let end = found.location + found.length
                if checkEnd && end < string.length && isWordChar(string.character(at: end)) {
                    accepted = false
                }
            }
            if accepted {
                result.append((found, keyword))
            }
            let next = found.location + max(1, found.length)
            if next >= length {
                break
            }
            searchRange = NSRange(location: next, length: length - next)
        }
    }
    return result
}

/// The first keyword (in folder order) that occurs in `text`, or nil.
public func keywordFolderFirstMatch(text: String, keywords: [String]) -> String? {
    if text.isEmpty {
        return nil
    }
    for keyword in keywords {
        if !keywordFolderRanges(in: text, keywords: [keyword]).isEmpty {
            return keyword
        }
    }
    return nil
}

// MARK: - Folder content

/// Hits among the latest cached messages of the given chats (`nil` = every chat in the chat list).
/// Returns the hits per folder and the chats that were looked at.
private func scanKeywordFolderMatches(context: AccountContext, folders: [KeywordFolder], peerIds: [EnginePeer.Id]?) -> Signal<(hits: [Int32: Set<EnginePeer.Id>], scanned: Set<EnginePeer.Id>), NoError> {
    return context.account.postbox.transaction { transaction -> (hits: [Int32: Set<EnginePeer.Id>], scanned: Set<EnginePeer.Id>) in
        var result: [Int32: Set<EnginePeer.Id>] = [:]
        var peers: [EnginePeer] = []
        if let peerIds {
            for peerId in peerIds {
                if let peer = transaction.getPeer(peerId) {
                    peers.append(EnginePeer(peer))
                }
            }
        } else {
            for groupId in [EngineChatList.Group.root, EngineChatList.Group.archive] {
                for peer in transaction.getChatListPeers(groupId: groupId._asGroup(), filterPredicate: nil, additionalFilter: nil) {
                    if peers.count >= keywordFoldersMaxScannedChats {
                        break
                    }
                    peers.append(EnginePeer(peer))
                }
            }
        }
        var scanned = Set<EnginePeer.Id>()
        for peer in peers {
            let peerId = peer.id
            scanned.insert(peerId)
            let candidates = folders.filter { $0.includes(peer: peer) }
            if candidates.isEmpty {
                continue
            }
            for namespace in [Namespaces.Message.Cloud, Namespaces.Message.Local] {
                transaction.scanTopMessages(peerId: peerId, namespace: namespace, limit: keywordFoldersRecentMessageLimit, { message in
                    let text = message.text
                    if text.isEmpty {
                        return true
                    }
                    for folder in candidates {
                        if result[folder.id]?.contains(peerId) == true {
                            continue
                        }
                        if keywordFolderFirstMatch(text: text, keywords: folder.keywords) != nil {
                            result[folder.id, default: Set()].insert(peerId)
                        }
                    }
                    return true
                })
            }
        }
        return (result, scanned)
    }
}

private func keywordFolderChatListFilter(folder: KeywordFolder, peerIds: Set<EnginePeer.Id>) -> ChatListFilter {
    var includePeers = ChatListFilterIncludePeers()
    for peerId in peerIds.sorted(by: { $0.toInt64() < $1.toInt64() }) {
        let _ = includePeers.addPeer(peerId)
    }
    return .filter(
        id: folder.filterId,
        title: ChatFolderTitle(text: folder.name, entities: [], enableAnimations: false),
        emoticon: nil,
        data: ChatListFilterData(
            isShared: false,
            hasSharedLinks: false,
            categories: [],
            excludeMuted: false,
            excludeRead: false,
            excludeArchived: false,
            includePeers: includePeers,
            excludePeers: [],
            color: nil
        )
    )
}

/// Keyword folders of the account as chat list filters whose included chats are the current matches.
///
/// All chats are scanned once per folder change; after that, every change of the top of the chat
/// list (new, edited or deleted messages) re-scans those chats, so a chat joins or leaves a folder
/// without waiting for the next full scan.
public func keywordFolderFilters(context: AccountContext) -> Signal<[(KeywordFolder, ChatListFilter)], NoError> {
    return combineLatest(keywordFolders(context: context), KeywordFoldersSettings.enabledSignal)
    |> mapToSignal { folders, enabled -> Signal<[(KeywordFolder, ChatListFilter)], NoError> in
        if folders.isEmpty || !enabled {
            return .single([])
        }
        // Re-scan only chats whose visible messages changed (new, edited or deleted message), not
        // on read-state or draft changes; results accumulate per chat for this folder set.
        let recentState = Atomic<(fingerprints: [EnginePeer.Id: String], hits: [Int32: Set<EnginePeer.Id>])>(value: ([:], [:]))
        let recent: Signal<(hits: [Int32: Set<EnginePeer.Id>], scanned: Set<EnginePeer.Id>)?, NoError> = .single(nil)
        |> then(
            context.engine.messages.chatList(group: .root, count: 100)
            |> map { chatList -> [(EnginePeer.Id, String)] in
                return chatList.items.compactMap { item -> (EnginePeer.Id, String)? in
                    guard case let .chatList(peerId) = item.id else {
                        return nil
                    }
                    let fingerprint = item.messages.map { "\($0.id.namespace):\($0.id.id):\($0.text.hashValue)" }.joined(separator: ",")
                    return (peerId, fingerprint)
                }
            }
            |> mapToSignal { entries -> Signal<(hits: [Int32: Set<EnginePeer.Id>], scanned: Set<EnginePeer.Id>)?, NoError> in
                let changed = recentState.with { state in
                    return entries.filter { state.fingerprints[$0.0] != $0.1 }
                }
                if changed.isEmpty {
                    return .complete()
                }
                // Debounce bursts; a newer update cancels a pending scan, and since fingerprints are
                // only stored after a scan finishes, the cancelled chats are picked up again.
                return (Signal<Void, NoError>.single(Void()) |> delay(0.3, queue: Queue.concurrentDefaultQueue()))
                |> mapToSignal { _ in
                    return scanKeywordFolderMatches(context: context, folders: folders, peerIds: changed.map { $0.0 })
                }
                |> map { result -> (hits: [Int32: Set<EnginePeer.Id>], scanned: Set<EnginePeer.Id>)? in
                    let state = recentState.modify { state in
                        var state = state
                        for (peerId, fingerprint) in changed {
                            state.fingerprints[peerId] = fingerprint
                        }
                        for folder in folders {
                            var hits = state.hits[folder.id] ?? Set()
                            hits.subtract(result.scanned)
                            hits.formUnion(result.hits[folder.id] ?? Set())
                            state.hits[folder.id] = hits
                        }
                        return state
                    }
                    return (state.hits, Set(state.fingerprints.keys))
                }
            }
        )
        return combineLatest(scanKeywordFolderMatches(context: context, folders: folders, peerIds: nil), recent)
        |> map { full, recent -> [(KeywordFolder, ChatListFilter)] in
            return folders.map { folder in
                var peerIds = full.hits[folder.id] ?? Set()
                if let recent {
                    // The newer scan of the top chats wins for those chats (adds and removals).
                    peerIds.subtract(recent.scanned)
                    peerIds.formUnion(recent.hits[folder.id] ?? Set())
                }
                return (folder, keywordFolderChatListFilter(folder: folder, peerIds: peerIds))
            }
        }
    }
}

/// Telegram's folders plus the keyword folders at their saved positions.
public func updatedChatListFiltersWithKeywordFolders(context: AccountContext) -> Signal<[ChatListFilter], NoError> {
    return combineLatest(context.engine.peers.updatedChatListFilters(), keywordFolderFilters(context: context))
    |> map { cloud, keyword -> [ChatListFilter] in
        if keyword.isEmpty {
            return cloud
        }
        var result = cloud
        if !result.contains(where: { filter in
            if case .allChats = filter {
                return true
            }
            return false
        }) {
            result.insert(.allChats, at: 0)
        }
        for (folder, filter) in keyword.sorted(by: { $0.0.position < $1.0.position }) {
            let index = max(0, min(result.count, Int(folder.position)))
            result.insert(filter, at: index)
        }
        return result
    }
    |> distinctUntilChanged
}

/// Cached messages of a chat that contain any of `keywords`, newest first.
public func keywordFolderHits(context: AccountContext, peerId: EnginePeer.Id, keywords: [String]) -> Signal<[(EngineMessage.Id, String)], NoError> {
    return context.account.postbox.transaction { transaction -> [(EngineMessage.Id, String)] in
        var result: [(EngineMessage.Id, String)] = []
        for namespace in [Namespaces.Message.Cloud, Namespaces.Message.Local] {
            transaction.scanTopMessages(peerId: peerId, namespace: namespace, limit: keywordFoldersJumpMessageLimit, { message in
                if let keyword = keywordFolderFirstMatch(text: message.text, keywords: keywords) {
                    result.append((message.id, keyword))
                }
                return true
            })
        }
        if result.count > 1 {
            result.sort(by: { $0.0.id > $1.0.id })
        }
        return result
    }
}

// MARK: - Strings

public enum KeywordFolderStrings {
    public static func isChinese(_ strings: PresentationStrings) -> Bool {
        let code = strings.primaryComponent.languageCode.lowercased()
        if code.hasPrefix("zh") {
            return true
        }
        if code.hasPrefix("en") {
            if let preferred = Locale.preferredLanguages.first?.lowercased(), preferred.hasPrefix("zh") {
                return true
            }
        }
        return false
    }

    private static func s(_ strings: PresentationStrings, _ zh: String, _ en: String) -> String {
        return isChinese(strings) ? zh : en
    }

    public static func title(_ s0: PresentationStrings) -> String { return s(s0, "关键词文件夹", "Keyword Folders") }
    public static func newFolder(_ s0: PresentationStrings) -> String { return s(s0, "新建关键词文件夹", "New Keyword Folder") }
    public static func editFolder(_ s0: PresentationStrings) -> String { return s(s0, "编辑关键词文件夹", "Edit Keyword Folder") }
    public static func menuItem(_ s0: PresentationStrings) -> String { return s(s0, "关键词文件夹", "Keyword Folder") }
    public static func newCloudFolder(_ s0: PresentationStrings) -> String { return s(s0, "新建文件夹", "New Folder") }
    public static func settingsInfo(_ s0: PresentationStrings) -> String {
        return s(s0, "关键词文件夹只保存在本机、按账号保存，不会同步到其他设备。最近消息里提到关键词的聊天会自动归入。", "Keyword folders are stored on this device for this account only and are not synced. Chats whose recent messages mention a keyword are added automatically.")
    }
    public static func nameHeader(_ s0: PresentationStrings) -> String { return s(s0, "文件夹名称", "FOLDER NAME") }
    public static func nameHint(_ s0: PresentationStrings) -> String { return s(s0, "例如：发票", "e.g. Invoices") }
    public static func keywordsHeader(_ s0: PresentationStrings) -> String { return s(s0, "关键词（1–10 个）", "KEYWORDS (1–10)") }
    public static func keywordHint(_ s0: PresentationStrings) -> String { return s(s0, "关键词", "Keyword") }
    public static func addKeyword(_ s0: PresentationStrings) -> String { return s(s0, "添加关键词", "Add Keyword") }
    public static func keywordsInfo(_ s0: PresentationStrings) -> String {
        return s(s0, "不区分大小写；中文按字词片段匹配，英文按整词匹配。只统计最近的消息：每个聊天的最后一条消息和最近 50 条已缓存在本机的消息。", "Case-insensitive. Chinese keywords match any part of the text, English keywords match whole words. Only recent messages are checked: the last message and the latest 50 messages cached on this device.")
    }
    public static func scopeHeader(_ s0: PresentationStrings) -> String { return s(s0, "范围", "INCLUDE") }
    public static func scopeAll(_ s0: PresentationStrings) -> String { return s(s0, "全部", "All") }
    public static func scopePrivate(_ s0: PresentationStrings) -> String { return s(s0, "私聊", "Private Chats") }
    public static func scopeGroups(_ s0: PresentationStrings) -> String { return s(s0, "群组", "Groups") }
    public static func scopeChannels(_ s0: PresentationStrings) -> String { return s(s0, "频道", "Channels") }
    public static func delete(_ s0: PresentationStrings) -> String { return s(s0, "删除关键词文件夹", "Delete Keyword Folder") }
    public static func deleteAlertTitle(_ s0: PresentationStrings) -> String { return s(s0, "删除文件夹", "Delete Folder") }
    public static func deleteAlertText(_ s0: PresentationStrings) -> String { return s(s0, "确定删除这个关键词文件夹吗？其中的聊天不会受影响。", "Delete this keyword folder? The chats in it will not be affected.") }
    // Validation feedback, same wording as Android (KeywordFolderStrings.java).
    public static func errorName(_ s0: PresentationStrings) -> String { return s(s0, "请输入文件夹名称", "Enter a folder name") }
    public static func errorKeywords(_ s0: PresentationStrings) -> String { return s(s0, "请至少填写一个关键词", "Enter at least one keyword") }
    public static func errorScope(_ s0: PresentationStrings) -> String { return s(s0, "请至少选择一个范围", "Choose at least one chat type") }
    public static func keywordsLimit(_ s0: PresentationStrings) -> String { return s(s0, "最多 10 个关键词", "Up to 10 keywords") }
    public static func limitReached(_ s0: PresentationStrings) -> String { return s(s0, "最多可以创建 10 个关键词文件夹", "You can create up to 10 keyword folders") }
    public static func filterInfo(_ s0: PresentationStrings, _ folder: KeywordFolder) -> String {
        return s(s0, "关键词：", "Keywords: ") + folder.keywords.joined(separator: s(s0, "、", ", "))
    }
    public static func jumpNext(_ s0: PresentationStrings, _ keyword: String) -> String { return s(s0, "跳到下一个「\(keyword)」", "Next \u{201C}\(keyword)\u{201D}") }
    public static func jumpNoMore(_ s0: PresentationStrings) -> String { return s(s0, "最近的消息里没有更多匹配，已回到最新一条", "No more matches in recent messages, back to the latest") }
    public static func jumpNone(_ s0: PresentationStrings) -> String { return s(s0, "最近的消息里没有找到关键词", "No keyword found in recent messages") }
}
