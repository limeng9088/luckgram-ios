import Foundation
import UIKit
import Display
import TelegramCore
import SwiftSignalKit

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

    /// The small buttons at the bottom right of the gallery (「文字」, 「译」) for a photo message;
    /// emits once the photo is downloaded and found to contain text, else an empty list.
    public static var viewerButtons: ((AccountContext, EngineMessage, ViewController?) -> Signal<[MenuItem], NoError>)?

    /// An action of the photo preview before sending (the attachment gallery).
    public struct AttachAction {
        public let title: String
        /// `image`: the photo; `present`: shows a native page over the preview; `replace`: puts a
        /// new image (e.g. the translated one) in place of this photo for sending.
        public let run: (_ image: UIImage, _ present: @escaping (UIViewController) -> Void, _ replace: @escaping (UIImage) -> Void) -> Void

        public init(title: String, run: @escaping (UIImage, @escaping (UIViewController) -> Void, @escaping (UIImage) -> Void) -> Void) {
            self.title = title
            self.run = run
        }
    }

    public static var attachPreviewActions: ((AccountContext) -> [AttachAction])?
}
