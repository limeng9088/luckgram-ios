import Foundation
import UIKit
import PhotosUI
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext
import LuckgramDiscover

// New post (spec 26 item 4): text up to 1000 characters and up to 9 photos. Photos come from the
// system photo picker (PHPicker: no photo-library permission, nothing else is read), are redrawn
// at ≤ 2048 px on the long edge and re-encoded as JPEG — a redrawn image carries no EXIF, so GPS
// never leaves the device — then uploaded through presigned URLs before the post is created.
// Same flow as SquareComposeActivity on Android.

private final class SquareComposeArguments {
    let updateText: (String) -> Void
    let addImages: () -> Void
    let removeImage: (Int) -> Void
    let clearImages: () -> Void

    init(updateText: @escaping (String) -> Void, addImages: @escaping () -> Void, removeImage: @escaping (Int) -> Void, clearImages: @escaping () -> Void) {
        self.updateText = updateText
        self.addImages = addImages
        self.removeImage = removeImage
        self.clearImages = clearImages
    }
}

private enum SquareComposeEntry: ItemListNodeEntry {
    case text(String, String)
    case image(Int, String, UIImage?)
    case add(String, Bool)
    case clear(String)
    case info(String)

    var section: ItemListSectionId {
        switch self {
        case .text:
            return 0
        case .image, .add, .clear, .info:
            return 1
        }
    }

    var stableId: Int {
        switch self {
        case .text: return 0
        case let .image(i, _, _): return 10 + i
        case .add: return 100
        case .clear: return 101
        case .info: return 102
        }
    }

    static func == (lhs: SquareComposeEntry, rhs: SquareComposeEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.text(a1, a2), .text(b1, b2)): return a1 == b1 && a2 == b2
        case let (.image(a1, a2, a3), .image(b1, b2, b3)): return a1 == b1 && a2 == b2 && a3 === b3
        case let (.add(a1, a2), .add(b1, b2)): return a1 == b1 && a2 == b2
        case let (.clear(a), .clear(b)): return a == b
        case let (.info(a), .info(b)): return a == b
        default: return false
        }
    }

    static func < (lhs: SquareComposeEntry, rhs: SquareComposeEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! SquareComposeArguments
        switch self {
        case let .text(text, placeholder):
            return ItemListMultilineInputItem(presentationData: presentationData, systemStyle: .glass, text: text, placeholder: placeholder, maxLength: ItemListMultilineInputItemTextLimit(value: SquareLogic.textMax, display: true), sectionId: self.section, style: .blocks, minimalHeight: 120.0, textUpdated: { value in
                arguments.updateText(value)
            })
        case let .image(index, title, thumbnail):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: thumbnail, title: title, label: "✕", sectionId: self.section, style: .blocks, disclosureStyle: .none, action: {
                arguments.removeImage(index)
            })
        case let .add(title, enabled):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: enabled ? .generic : .disabled, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.addImages()
            })
        case let .clear(title):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: .destructive, alignment: .natural, sectionId: self.section, style: .blocks, action: {
                arguments.clearImages()
            })
        case let .info(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

/// A photo ready to upload: JPEG bytes without metadata and a small thumbnail for the list.
struct LuckgramSquarePreparedImage {
    let jpeg: Data
    let width: Int
    let height: Int
    let thumbnail: UIImage?
}

enum LuckgramSquareImages {
    static let contentType = "image/jpeg"
    static let jpegQuality: CGFloat = 0.85

    /// Redraws `image` at ≤ 2048 px (long edge) and encodes it as JPEG. Drawing into a new
    /// bitmap drops every property of the original (orientation is applied, EXIF is gone).
    static func prepare(_ image: UIImage) -> LuckgramSquarePreparedImage? {
        let pixelWidth = Int(image.size.width * image.scale)
        let pixelHeight = Int(image.size.height * image.scale)
        let size = SquareLogic.scaledSize(width: pixelWidth, height: pixelHeight)
        guard size.width > 0, size.height > 0 else {
            return nil
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let target = CGSize(width: size.width, height: size.height)
        let redrawn = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let jpeg = redrawn.jpegData(compressionQuality: jpegQuality) else {
            return nil
        }
        let thumbSize = CGSize(width: 40.0, height: 40.0)
        let thumbnail = UIGraphicsImageRenderer(size: thumbSize, format: format).image { _ in
            let k = max(thumbSize.width / target.width, thumbSize.height / target.height)
            let drawSize = CGSize(width: target.width * k, height: target.height * k)
            redrawn.draw(in: CGRect(x: (thumbSize.width - drawSize.width) / 2.0, y: (thumbSize.height - drawSize.height) / 2.0, width: drawSize.width, height: drawSize.height))
        }
        return LuckgramSquarePreparedImage(jpeg: jpeg, width: size.width, height: size.height, thumbnail: thumbnail)
    }
}

private final class SquareComposeState {
    var text = ""
    var images: [LuckgramSquarePreparedImage] = []
    var preparing = false
    var publishing = false
}

/// PHPicker delegate kept alive by the controller while the picker is up.
private final class LuckgramSquarePickerDelegate: NSObject, PHPickerViewControllerDelegate {
    let completion: ([UIImage], Bool) -> Void

    init(completion: @escaping ([UIImage], Bool) -> Void) {
        self.completion = completion
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        if results.isEmpty {
            self.completion([], false)
            return
        }
        let group = DispatchGroup()
        var images: [UIImage?] = Array(repeating: nil, count: results.count)
        var failed = false
        for (i, result) in results.enumerated() {
            group.enter()
            result.itemProvider.loadObject(ofClass: UIImage.self) { object, _ in
                if let image = object as? UIImage {
                    images[i] = image
                } else {
                    failed = true
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            self.completion(images.compactMap { $0 }, failed)
        }
    }
}

public func luckgramSquareComposeController(context: AccountContext) -> ViewController {
    let tx = LuckgramSquare.texts
    let state = SquareComposeState()
    let updated = ValuePromise<Int>(0, ignoreRepeated: false)
    var version = 0
    func refresh() {
        version += 1
        updated.set(version)
    }

    var presentImpl: ((ViewController) -> Void)?
    var pushImpl: ((ViewController) -> Void)?
    var dismissImpl: (() -> Void)?
    var presentNativeImpl: ((UIViewController) -> Void)?
    let present: (ViewController) -> Void = { presentImpl?($0) }
    let push: (ViewController) -> Void = { pushImpl?($0) }
    let requests = DisposableSet()
    var pickerDelegate: LuckgramSquarePickerDelegate?

    func fail(_ error: LuckgramAIError) {
        state.publishing = false
        refresh()
        LuckgramSquare.showError(error, context: context, present: present, push: push)
    }

    func createPost(_ keys: [String]) {
        requests.add(LuckgramAI.shared.requestJSON(method: "POST", path: "/v1/square/posts", body: SquareLogic.postBody(text: state.text, imageKeys: keys)).start(next: { j in
            state.publishing = false
            let p = SquareLogic.parsePost(j)
            if !p.author.id.isEmpty {
                LuckgramSquare.myAuthorId = p.author.id
            }
            LuckgramSquare.markChanged()
            dismissImpl?()
            LuckgramSquare.toast(context: context, tx.published, present: present)
        }, error: { error in
            fail(error)
        }))
    }

    func uploadAll(_ uploads: [SquareLogic.Upload]) {
        var keys: [String] = []
        let signals = state.images.enumerated().map { i, image in
            LuckgramAI.shared.putPresigned(url: uploads[i].url, contentType: LuckgramSquareImages.contentType, body: image.jpeg)
            |> map { _ -> String in uploads[i].key }
        }
        var chain: Signal<[String], LuckgramAIError> = .single([])
        for s in signals {
            chain = chain |> mapToSignal { acc -> Signal<[String], LuckgramAIError> in
                return s |> map { key in acc + [key] }
            }
        }
        requests.add((chain |> deliverOnMainQueue).start(next: { all in
            keys = all
        }, error: { error in
            fail(error)
        }, completed: {
            if keys.count == state.images.count {
                createPost(keys)
            } else {
                fail(LuckgramAIError(code: LuckgramAIError.upstreamUnavailable))
            }
        }))
    }

    func publish() {
        if state.publishing || state.preparing {
            return
        }
        if !SquareLogic.isValidPost(text: state.text, images: state.images.count) {
            LuckgramSquare.toast(context: context, SquareLogic.length(state.text.trimmingCharacters(in: .whitespacesAndNewlines)) > SquareLogic.textMax ? tx.tooLong : tx.needContent, present: present)
            return
        }
        requests.add(LuckgramSquare.requireProfile(context: context, present: present, push: push, then: {
            state.publishing = true
            refresh()
            if state.images.isEmpty {
                createPost([])
                return
            }
            requests.add(LuckgramAI.shared.requestJSON(method: "POST", path: "/v1/square/uploads", body: SquareLogic.uploadsBody(count: state.images.count, contentType: LuckgramSquareImages.contentType)).start(next: { j in
                let uploads = SquareLogic.parseUploads(j)
                if uploads.count < state.images.count {
                    fail(LuckgramAIError(code: LuckgramAIError.upstreamUnavailable))
                    return
                }
                uploadAll(uploads)
            }, error: { error in
                fail(error)
            }))
        }))
    }

    func pickImages() {
        let room = SquareLogic.imagesMax - state.images.count
        guard room > 0, !state.preparing, !state.publishing else {
            return
        }
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = room
        let picker = PHPickerViewController(configuration: config)
        let delegate = LuckgramSquarePickerDelegate(completion: { images, failed in
            pickerDelegate = nil
            if images.isEmpty {
                if failed {
                    LuckgramSquare.toast(context: context, tx.imageFailed, present: present)
                }
                return
            }
            state.preparing = true
            refresh()
            DispatchQueue.global(qos: .userInitiated).async {
                let prepared = images.compactMap { LuckgramSquareImages.prepare($0) }
                DispatchQueue.main.async {
                    state.preparing = false
                    for p in prepared where state.images.count < SquareLogic.imagesMax {
                        state.images.append(p)
                    }
                    refresh()
                    if failed || prepared.count < images.count {
                        LuckgramSquare.toast(context: context, tx.imageFailed, present: present)
                    }
                }
            }
        })
        pickerDelegate = delegate
        picker.delegate = delegate
        presentNativeImpl?(picker)
    }

    let arguments = SquareComposeArguments(updateText: { text in
        state.text = text
    }, addImages: {
        pickImages()
    }, removeImage: { index in
        if !state.publishing && index < state.images.count {
            state.images.remove(at: index)
            refresh()
        }
    }, clearImages: {
        if !state.publishing {
            state.images.removeAll()
            refresh()
        }
    })

    let entries = updated.get() |> map { _ -> [SquareComposeEntry] in
        var e: [SquareComposeEntry] = [.text(state.text, tx.textHint)]
        for (i, image) in state.images.enumerated() {
            e.append(.image(i, "\(image.width) × \(image.height)", image.thumbnail))
        }
        if state.preparing {
            e.append(.info(tx.preparingImages))
        } else {
            if state.images.count < SquareLogic.imagesMax {
                e.append(.add(tx.addImages(state.images.count), !state.publishing))
            }
            if !state.images.isEmpty {
                e.append(.clear(tx.removeImages))
            }
            e.append(.info(tx.imagesInfo + "\n\n" + tx.dailyLimitInfo(LuckgramSquare.maxPostsPerDay)))
        }
        return e
    }

    let signal = combineLatest(context.sharedContext.presentationData, entries)
    |> map { presentationData, entries -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let rightButton = ItemListNavigationButton(content: .text(state.publishing ? tx.publishing : tx.publish), style: .bold, enabled: !state.publishing && !state.preparing, action: {
            publish()
        })
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(tx.composeTitle), leftNavigationButton: nil, rightNavigationButton: rightButton, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, emptyStateItem: nil, animateChanges: false)
        return (controllerState, (listState, arguments))
    }

    let controller = ItemListController(context: context, state: signal)
    presentImpl = { [weak controller] c in
        controller?.present(c, in: .window(.root))
    }
    pushImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }
    dismissImpl = { [weak controller] in
        controller?.dismiss()
    }
    presentNativeImpl = { [weak controller] native in
        if let window = context.sharedContext.mainWindow {
            window.presentNative(native)
        } else {
            controller?.view.window?.rootViewController?.present(native, animated: true)
        }
    }
    return controller
}
