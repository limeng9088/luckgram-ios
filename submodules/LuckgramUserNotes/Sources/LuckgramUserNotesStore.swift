// Luckgram — private notes (spec 05).
// Licensed under GNU GPL v. 2 or later, like the Telegram iOS sources it builds on.

import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext

/// Local, per-account storage of private notes about users, groups and channels.
///
/// The notes file lives in the account's own directory (`account.basePath`), so:
/// - two accounts never share notes;
/// - TelegramCore removes the directory when the account logs out or is deleted
///   (`managedCleanupAccounts` deletes every `account-*` directory that has no live record);
/// - nothing is uploaded, and uninstalling the app removes the container.
public final class LuckgramUserNotesStore {
    /// Feature switch key, registered in the Luckgram settings registry (spec 00). Device-wide, default on.
    public static let featureKey = "user_notes"
    public static let maxLength = 2000

    public static var isEnabled: Bool {
        if let value = UserDefaults.standard.object(forKey: "luckgram.\(featureKey)") as? Bool {
            return value
        }
        return true
    }

    public struct Note: Equatable {
        public let peerId: EnginePeer.Id
        public let text: String
        public let updatedAt: Double
    }

    private struct StoredEntry: Codable {
        var text: String
        var updatedAt: Double
        var expanded: Bool
    }

    private struct StoredFile: Codable {
        var version: Int
        var notes: [String: StoredEntry]
    }

    public static func shared(context: AccountContext) -> LuckgramUserNotesStore {
        return shared(basePath: context.account.basePath)
    }

    public static func shared(basePath: String) -> LuckgramUserNotesStore {
        if let current = storesByPath[basePath] {
            return current
        }
        let store = LuckgramUserNotesStore(basePath: basePath)
        storesByPath[basePath] = store
        return store
    }

    private let filePath: String
    private var entries: [Int64: StoredEntry] = [:]
    private let updatesPipe = ValuePipe<Void>()

    /// Fires (on the main thread) whenever a note or a bar state changes.
    public var updates: Signal<Void, NoError> {
        return self.updatesPipe.signal()
    }

    private init(basePath: String) {
        self.filePath = basePath + "/luckgram-user-notes.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: self.filePath)), let file = try? JSONDecoder().decode(StoredFile.self, from: data) {
            for (key, value) in file.notes {
                if let id = Int64(key), !value.text.isEmpty {
                    self.entries[id] = value
                }
            }
        }
    }

    public func note(peerId: EnginePeer.Id) -> String? {
        return self.entries[peerId.toInt64()]?.text
    }

    public func setNote(peerId: EnginePeer.Id, text: String?) {
        var value = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count > LuckgramUserNotesStore.maxLength {
            value = String(value.prefix(LuckgramUserNotesStore.maxLength))
        }
        let key = peerId.toInt64()
        if value.isEmpty {
            self.entries.removeValue(forKey: key)
        } else {
            let expanded = self.entries[key]?.expanded ?? false
            self.entries[key] = StoredEntry(text: value, updatedAt: Date().timeIntervalSince1970, expanded: expanded)
        }
        self.persist()
    }

    /// Whether the chat top bar is expanded for this peer (remembered per chat, default collapsed).
    public func isBarExpanded(peerId: EnginePeer.Id) -> Bool {
        return self.entries[peerId.toInt64()]?.expanded ?? false
    }

    public func setBarExpanded(peerId: EnginePeer.Id, expanded: Bool) {
        let key = peerId.toInt64()
        guard var entry = self.entries[key], entry.expanded != expanded else {
            return
        }
        entry.expanded = expanded
        self.entries[key] = entry
        self.persist()
    }

    /// All notes, most recently edited first.
    public func allNotes() -> [Note] {
        return self.entries.map { key, value in
            Note(peerId: EnginePeer.Id(key), text: value.text, updatedAt: value.updatedAt)
        }.sorted(by: { $0.updatedAt > $1.updatedAt })
    }

    /// Removes every note of this account.
    public func wipe() {
        self.entries.removeAll()
        try? FileManager.default.removeItem(atPath: self.filePath)
        self.updatesPipe.putNext(Void())
    }

    private func persist() {
        var notes: [String: StoredEntry] = [:]
        for (key, value) in self.entries {
            notes["\(key)"] = value
        }
        if let data = try? JSONEncoder().encode(StoredFile(version: 1, notes: notes)) {
            try? data.write(to: URL(fileURLWithPath: self.filePath), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        self.updatesPipe.putNext(Void())
    }

    public static func firstLine(_ text: String) -> String {
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return ""
    }
}

private var storesByPath: [String: LuckgramUserNotesStore] = [:]
