import Foundation
import UIKit
import Display
import AccountContext
import TelegramCore

/// Entry points for image features (specs#106 OCR, specs#108 image translation): the photo
/// long-press menu and the viewer's "⋯" menu (`.menu`), the small buttons at the bottom right of
/// the full-screen viewer (`.viewerButton`) and the gallery preview before sending
/// (`.attachPreview`). Those places list `actions(at:)`; a feature adds one `register(...)` line in
/// `registerBuiltInsIfNeeded` and doesn't touch the chat / gallery code. Main thread only.
public enum LuckgramImageActions {
    public struct Place: OptionSet {
        public let rawValue: Int

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }

        public static let menu = Place(rawValue: 1)
        public static let viewerButton = Place(rawValue: 2)
        public static let attachPreview = Place(rawValue: 4)
    }

    /// Where an action runs and what it gets.
    public struct Target {
        public let context: AccountContext
        /// The page to present on (chat, gallery, attach preview).
        public let controller: ViewController?
        public let image: UIImage
        /// Cache key for `LuckgramOcr` (the image file's path), or nil.
        public let imageKey: String?
        /// The photo message, or nil in the gallery preview.
        public let message: EngineMessage?
        /// Gives a new image (e.g. the translated one, #108) back to the gallery preview, replacing
        /// the current item before sending. Only set for `.attachPreview`; nil = don't offer it.
        public let replaceImage: ((UIImage) -> Void)?

        public init(context: AccountContext, controller: ViewController?, image: UIImage, imageKey: String?, message: EngineMessage?, replaceImage: ((UIImage) -> Void)? = nil) {
            self.context = context
            self.controller = controller
            self.image = image
            self.imageKey = imageKey
            self.message = message
            self.replaceImage = replaceImage
        }
    }

    public struct Action {
        public let id: String
        public let title: (String, String)
        /// SF Symbol for menus.
        public let icon: String?
        /// Short label of the viewer button (e.g. 「文字」 / 「译」).
        public let buttonTitle: (String, String)
        public let places: Place
        public let isVisible: (EngineMessage?) -> Bool
        public let run: (Target) -> Void

        public init(id: String, title: (String, String), icon: String? = nil, buttonTitle: (String, String), places: Place, isVisible: @escaping (EngineMessage?) -> Bool = { _ in true }, run: @escaping (Target) -> Void) {
            self.id = id
            self.title = title
            self.icon = icon
            self.buttonTitle = buttonTitle
            self.places = places
            self.isVisible = isVisible
            self.run = run
        }

        public var localizedTitle: String {
            return LuckgramStrings.pick(self.title.0, self.title.1)
        }

        public var localizedButtonTitle: String {
            return LuckgramStrings.pick(self.buttonTitle.0, self.buttonTitle.1)
        }
    }

    private static var list: [Action] = []
    private static var builtInsRegistered = false

    static func registerBuiltInsIfNeeded() {
        if builtInsRegistered {
            return
        }
        builtInsRegistered = true
        // ---- image features register here, one line each ----
        list.append(Action(id: "ocr", title: ("识别文字", "Recognize Text"), icon: "text.viewfinder", buttonTitle: ("文字", "Text"), places: [.menu, .viewerButton, .attachPreview], isVisible: { _ in
            return LuckgramOcr.isEnabled
        }, run: { target in
            LuckgramOcrSheetController.open(context: target.context, image: target.image, key: target.imageKey)
        })) // specs#106
        list.append(LuckgramImageTranslateEntry.action()) // specs#108
    }

    /// Replaces an action with the same id.
    public static func register(_ action: Action) {
        registerBuiltInsIfNeeded()
        list.removeAll(where: { $0.id == action.id })
        list.append(action)
    }

    public static func unregister(id: String) {
        list.removeAll(where: { $0.id == id })
    }

    /// Registered actions shown at `place`, in registration order.
    public static func actions(at place: Place) -> [Action] {
        registerBuiltInsIfNeeded()
        return list.filter { $0.places.contains(place) }
    }

    /// Called once at startup: the gallery's 「⋯」 menu lists the `.menu` actions for photos.
    public static func installGalleryHook() {
        LuckgramGalleryHooks.menuItems = { context, message, controller in
            guard isPhoto(message) else {
                return []
            }
            return visibleActions(at: .menu, message: message).map { action in
                LuckgramGalleryHooks.MenuItem(title: action.localizedTitle, icon: action.icon, action: { [weak controller] in
                    guard let loaded = image(context: context, message: message) else {
                        return
                    }
                    action.run(Target(context: context, controller: controller, image: loaded.0, imageKey: loaded.1, message: message))
                })
            }
        }
    }

    /// Whether `message` is a photo (the menu entries only apply to photos).
    public static func isPhoto(_ message: EngineMessage) -> Bool {
        return message.media.contains(where: { $0 is TelegramMediaImage })
    }

    /// The downloaded full-size image of a photo message and its cache key (the file path), or nil
    /// when it isn't a photo or hasn't been downloaded.
    public static func image(context: AccountContext, message: EngineMessage) -> (UIImage, String)? {
        for media in message.media {
            guard let image = media as? TelegramMediaImage, let rep = largestImageRepresentation(image.representations) else {
                continue
            }
            if let path = context.engine.resources.completedResourcePath(id: EngineMediaResource.Id(rep.resource.id)), let ui = UIImage(contentsOfFile: path) {
                return (ui, path)
            }
        }
        return nil
    }

    /// Actions at `place` that are visible for `message`.
    public static func visibleActions(at place: Place, message: EngineMessage?) -> [Action] {
        return actions(at: place).filter { $0.isVisible(message) }
    }
}
