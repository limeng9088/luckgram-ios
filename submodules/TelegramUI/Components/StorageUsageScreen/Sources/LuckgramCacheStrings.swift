import Foundation
import TelegramPresentationData

/// Luckgram 08 (cache): UI strings for the storage-usage extensions.
///
/// Chinese is shown when either the app language or the system language is Chinese, English
/// otherwise. Kept local to this feature so it does not depend on server language packs.
public enum LuckgramCacheStrings {
    public static let oneHour: Int32 = 60 * 60
    public static let oneDay: Int32 = 24 * 60 * 60
    public static let threeDays: Int32 = 3 * 24 * 60 * 60
    public static let oneWeek: Int32 = 7 * 24 * 60 * 60
    /// Telegram stores "1 month" as 31 days.
    public static let oneMonth: Int32 = 31 * 24 * 60 * 60
    public static let forever: Int32 = Int32.max

    /// Keep-media options for private chats, groups, channels and single chats.
    public static let keepMediaOptions: [Int32] = [forever, oneMonth, oneWeek, threeDays, oneDay, oneHour]
    /// Cache size limit options in gigabytes; `Int32.max` means no limit.
    public static let cacheLimitOptions: [Int32] = [1, 2, 5, 10, 20, 50, Int32.max]

    public static func isChinese(_ strings: PresentationStrings) -> Bool {
        if strings.baseLanguageCode.lowercased().hasPrefix("zh") {
            return true
        }
        if let language = Locale.preferredLanguages.first, language.lowercased().hasPrefix("zh") {
            return true
        }
        return false
    }

    private static func t(_ strings: PresentationStrings, _ zh: String, _ en: String) -> String {
        return isChinese(strings) ? zh : en
    }

    /// Label of a keep-media value in seconds.
    public static func keepMedia(_ strings: PresentationStrings, value: Int32) -> String {
        switch value {
        case forever:
            return t(strings, "永久", "Forever")
        case oneHour:
            return t(strings, "1 小时", "1 hour")
        case oneDay:
            return t(strings, "1 天", "1 day")
        case 2 * oneDay:
            return t(strings, "2 天", "2 days")
        case threeDays:
            return t(strings, "3 天", "3 days")
        case oneWeek:
            return t(strings, "1 周", "1 week")
        case oneMonth:
            return t(strings, "1 个月", "1 month")
        default:
            return timeIntervalString(strings: strings, value: value)
        }
    }

    /// Maps a stored limit (older versions offered e.g. 4, 8, 16, 32 GB) to the nearest larger option.
    public static func normalizedCacheLimit(_ value: Int32) -> Int32 {
        for option in cacheLimitOptions where option >= value {
            return option
        }
        return Int32.max
    }

    public static func cacheLimit(_ strings: PresentationStrings, gigabytes: Int32) -> String {
        if gigabytes == Int32.max {
            return t(strings, "不限", "No limit")
        }
        return "\(gigabytes) GB"
    }

    public static func cacheLimitTitle(_ strings: PresentationStrings) -> String {
        return t(strings, "缓存上限", "Cache limit")
    }

    public static func cacheLimitInfo(_ strings: PresentationStrings) -> String {
        return t(strings, "超过上限时，最久未打开的缓存会先被自动清理。收藏夹里的媒体和正在下载的文件不会被清理。", "When the cache grows beyond the limit, the files you haven't opened for the longest time are removed first. Media in Saved Messages and files being downloaded are kept.")
    }

    public static func chatKeepMediaHeader(_ strings: PresentationStrings) -> String {
        return t(strings, "本聊天媒体保留时间", "KEEP MEDIA FOR THIS CHAT")
    }

    public static func chatKeepMediaTitle(_ strings: PresentationStrings) -> String {
        return t(strings, "保留时间", "Keep media")
    }

    public static func followCategory(_ strings: PresentationStrings, categoryValue: String) -> String {
        return isChinese(strings) ? "跟随分类（\(categoryValue)）" : "Default (\(categoryValue))"
    }

    public static func useCategoryDefault(_ strings: PresentationStrings, categoryValue: String) -> String {
        return isChinese(strings) ? "使用分类默认值（\(categoryValue)）" : "Use default (\(categoryValue))"
    }

    public static func chatKeepMediaInfo(_ strings: PresentationStrings, size: String) -> String {
        return isChinese(strings) ? "该聊天在本机占用 \(size)。这里的设置会覆盖私聊 / 群组 / 频道的分类设置。" : "This chat uses \(size) on this device. This setting overrides the private chats / groups / channels setting."
    }

    public static func savedMessagesKept(_ strings: PresentationStrings) -> String {
        return t(strings, "收藏夹里的媒体永久保留，不会被自动清理。", "Media in Saved Messages is always kept and never removed automatically.")
    }

    /// Profile "…" menu entry.
    public static func profileMenuStorage(_ strings: PresentationStrings) -> String {
        return t(strings, "存储空间与保留时间", "Storage and keep media")
    }

    /// Text of the "clear now" confirmation.
    public static func willFree(_ strings: PresentationStrings, size: String) -> String {
        return isChinese(strings) ? "将释放 \(size) 的本机空间。云端的文件不会被删除。" : "This will free up \(size) on this device. Files stay in the cloud."
    }
}
