// Luckgram — profile details (spec 07).
// Licensed under GNU GPL v. 2 or later.

import Foundation

/// Pure rules of spec 07. Foundation-only so they run as SwiftPM tests on Linux
/// (`Tests/LuckgramProfileInfoLogicTests.swift`). Same rules as Android `ProfileInfoLogic`.
public enum LuckgramProfileInfoLogic {
    public enum PeerType {
        case user
        case legacyGroup
        /// Channels and supergroups.
        case channel
    }

    /// ID as shown and copied: users / bots as is, legacy groups `-id`, channels / supergroups `-100id`.
    public static func displayId(_ type: PeerType, id: Int64) -> String {
        switch type {
        case .user:
            return "\(id)"
        case .legacyGroup:
            return "-\(id)"
        case .channel:
            return "-100\(id)"
        }
    }

    /// Link for "Copy link": only users / bots have one.
    public static func userLink(_ type: PeerType, id: Int64) -> String? {
        if case .user = type {
            return "tg://user?id=\(id)"
        }
        return nil
    }

    public struct Point: Equatable {
        public let id: Int64
        /// year * 12 + (month - 1)
        public let monthIndex: Int
    }

    public enum Estimate: Equatable {
        case month(year: Int, month: Int)
        case before2014
    }

    /// Parses the bundled table ("id,YYYY-MM" per line, '#' comments). Malformed or out-of-order lines are skipped.
    public static func parseTable(_ text: String?) -> [Point] {
        var points: [Point] = []
        guard let text else {
            return points
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            let parts = line.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let id = Int64(parts[0]) else {
                continue
            }
            let date = Array(parts[1])
            guard date.count >= 7, date[4] == "-", let year = Int(String(date[0..<4])), let month = Int(String(date[5..<7])), (1...12).contains(month) else {
                continue
            }
            let point = Point(id: id, monthIndex: year * 12 + month - 1)
            if let last = points.last, point.id <= last.id || point.monthIndex < last.monthIndex {
                continue
            }
            points.append(point)
        }
        return points
    }

    /// Approximate registration month by linear interpolation between table rows.
    /// Below the first row: before 2014. Newer than the table or no table: nil (row not shown).
    public static func estimate(_ points: [Point], userId: Int64) -> Estimate? {
        guard points.count >= 2, userId > 0 else {
            return nil
        }
        if userId < points[0].id {
            return .before2014
        }
        for i in 0 ..< points.count - 1 {
            let a = points[i]
            let b = points[i + 1]
            if userId >= a.id && userId < b.id {
                let t = Double(userId - a.id) / Double(b.id - a.id)
                let m = a.monthIndex + Int((t * Double(b.monthIndex - a.monthIndex)).rounded(.down))
                if m < 2014 * 12 {
                    return .before2014
                }
                return .month(year: m / 12, month: m % 12 + 1)
            }
        }
        return nil
    }

    private static let monthsEn = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// "约 2019 年 10 月" / "about Oct 2019"; "早于 2014 年" / "before 2014".
    public static func format(_ estimate: Estimate, chinese: Bool) -> String {
        switch estimate {
        case .before2014:
            return chinese ? "早于 2014 年" : "before 2014"
        case let .month(year, month):
            return chinese ? "约 \(year) 年 \(month) 月" : "about \(monthsEn[month - 1]) \(year)"
        }
    }
}
