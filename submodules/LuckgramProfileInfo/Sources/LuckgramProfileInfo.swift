// Luckgram — profile details (spec 07).
// Licensed under GNU GPL v. 2 or later.

import Foundation
import AppBundle
import LuckgramUI

/// App glue for spec 07: switch, strings and the bundled registration-date table.
public enum LuckgramProfileInfo {
    /// Registered in `LuckgramFeatures` (default on).
    public static let featureKey = "profile_details"

    public static var isEnabled: Bool {
        return LuckgramSettings.shared.isEnabled(featureKey)
    }

    private static let table: [LuckgramProfileInfoLogic.Point] = {
        guard let path = getAppBundle().path(forResource: "LuckgramRegistrationDates", ofType: "txt"), let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return []
        }
        return LuckgramProfileInfoLogic.parseTable(text)
    }()

    /// "约 2019 年 10 月" etc., or nil when the row should not be shown.
    public static func registrationText(userId: Int64) -> String? {
        guard let estimate = LuckgramProfileInfoLogic.estimate(table, userId: userId) else {
            return nil
        }
        return LuckgramProfileInfoLogic.format(estimate, chinese: LuckgramStrings.isChinese)
    }

    public static var idTitle: String { return "ID" }
    public static var idCopied: String { return LuckgramStrings.pick("ID 已复制", "ID copied") }
    public static var linkCopied: String { return LuckgramStrings.pick("链接已复制", "Link copied") }
    public static var copyId: String { return LuckgramStrings.pick("复制 ID", "Copy ID") }
    public static var copyLink: String { return LuckgramStrings.pick("复制链接", "Copy link") }
    public static var registeredTitle: String { return LuckgramStrings.pick("注册时间", "Registered") }
    public static var registeredInfo: String { return LuckgramStrings.pick("按 ID 估算", "estimated from ID") }
}
