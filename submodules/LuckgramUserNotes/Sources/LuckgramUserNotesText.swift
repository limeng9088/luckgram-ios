// Luckgram — private notes (spec 05).
// Licensed under GNU GPL v. 2 or later.

import Foundation

/// Text rules of private notes. Foundation-only so they run as SwiftPM tests on Linux
/// (`Tests/LuckgramUserNotesTextTests.swift`). Same rules as Android `UserNotesText`.
public enum LuckgramUserNotesText {
    public static let maxLength = 2000

    /// Text as stored: trimmed and cut to `maxLength` characters. Empty means "no note".
    public static func normalize(_ text: String?) -> String {
        var value = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count > maxLength {
            value = String(value.prefix(maxLength))
        }
        return value
    }

    /// Whether the editor accepts this text (the editor refuses input past the limit).
    public static func isWithinLimit(_ text: String) -> Bool {
        return text.count <= maxLength
    }

    /// First non-empty line, trimmed; shown in the collapsed chat bar and in "All notes".
    public static func firstLine(_ text: String?) -> String {
        guard let text else {
            return ""
        }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return ""
    }

    private static func contains(_ text: String, _ query: String) -> Bool {
        return text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// "All notes" search: an empty query matches everything; otherwise the note text or the name contains it.
    public static func matches(query: String, note: String, name: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            return true
        }
        return contains(note, q) || contains(name, q)
    }

    /// Line shown under the name in "All notes": the first line containing the query, else the first line.
    public static func snippet(note: String, query: String) -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            for line in note.components(separatedBy: .newlines) where contains(line, q) {
                return line.trimmingCharacters(in: .whitespaces)
            }
        }
        return firstLine(note)
    }
}
