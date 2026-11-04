import Foundation
import UIKit
import Display
import TelegramCore

/// Luckgram specs#106 / #108: lets the gallery (GalleryUI, which can't import LuckgramUI) show the
/// registered image actions (「识别文字」, 「翻译图片」) in its 「⋯」 menu. Set once at startup by
/// LuckgramUI (`LuckgramImageActions.installGalleryHook()`); nil = no entries.
public enum LuckgramGalleryHooks {
    public struct MenuItem {
        public let title: String
        /// SF Symbol.
        public let icon: String?
        public let action: () -> Void

        public init(title: String, icon: String?, action: @escaping () -> Void) {
            self.title = title
            self.icon = icon
            self.action = action
        }
    }

    /// The 「⋯」 entries for a photo message shown in the gallery; `controller` is the gallery.
    public static var menuItems: ((AccountContext, EngineMessage, ViewController?) -> [MenuItem])?
}
