import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import SSignalKit
import TelegramPresentationData
import AccountContext
import LegacyComponents
import LegacyUI
import LegacyMediaPickerUI
import Photos
import MediaAssetsContext

private func galleryFetchResultItems(
    fetchResult: PHFetchResult<PHAsset>,
    index: Int,
    reversed: Bool,
    selectionContext: TGMediaSelectionContext?,
    editingContext: TGMediaEditingContext,
    stickersContext: TGPhotoPaintStickersContext,
    immediateThumbnail: UIImage?,
    asFile: Bool
) -> ([TGModernGalleryItem], TGModernGalleryItem?) {
    var focusItem: TGModernGalleryItem?
    var galleryItems: [TGModernGalleryItem] = []
    
    let legacyFetchResult = TGMediaAssetFetchResult(phFetchResult: fetchResult as? PHFetchResult<AnyObject>, reversed: reversed)
    
    for i in 0 ..< fetchResult.count {
        if let galleryItem = TGMediaPickerGalleryFetchResultItem(fetchResult: legacyFetchResult, index: UInt(i)) {
            galleryItem.selectionContext = selectionContext
            galleryItem.editingContext = editingContext
            galleryItem.stickersContext = stickersContext
            galleryItem.asFile = asFile
            galleryItems.append(galleryItem)
            
            if i == index {
                galleryItem.immediateThumbnailImage = immediateThumbnail
                focusItem = galleryItem
            }
        }
    }
    return (galleryItems, focusItem)
}

private func gallerySelectionItems(item: TGMediaSelectableItem, selectionContext: TGMediaSelectionContext?, editingContext: TGMediaEditingContext, stickersContext: TGPhotoPaintStickersContext, immediateThumbnail: UIImage?) -> ([TGModernGalleryItem], TGModernGalleryItem?) {
    var focusItem: TGModernGalleryItem?
    var galleryItems: [TGModernGalleryItem] = []
    
    if let selectionContext = selectionContext {
        for case let selectedItem as TGMediaSelectableItem in selectionContext.selectedItems() {
            if let asset = selectedItem as? TGMediaAsset {
                let galleryItem: (TGModernGallerySelectableItem & TGModernGalleryEditableItem)
                switch asset.type {
                    case TGMediaAssetVideoType:
                        galleryItem = TGMediaPickerGalleryVideoItem(asset: asset)
                    case TGMediaAssetGifType:
                        let convertedAsset = TGCameraCapturedVideo(asset: asset, livePhoto: false)
                        galleryItem = TGMediaPickerGalleryVideoItem(asset: convertedAsset)
                    default:
                        galleryItem = TGMediaPickerGalleryPhotoItem(asset: asset)
                }
                galleryItem.selectionContext = selectionContext
                galleryItem.editingContext = editingContext
                galleryItem.stickersContext = stickersContext
                galleryItems.append(galleryItem)
                
                if selectedItem.uniqueIdentifier == item.uniqueIdentifier {
                    if let galleryItem = galleryItem as? TGMediaPickerGalleryItem {
                        galleryItem.immediateThumbnailImage = immediateThumbnail
                    }
                    focusItem = galleryItem
                }
            } else if let asset = selectedItem as? UIImage {
                let galleryItem: (TGModernGallerySelectableItem & TGModernGalleryEditableItem) = TGMediaPickerGalleryPhotoItem(asset: asset)
                galleryItem.selectionContext = selectionContext
                galleryItem.editingContext = editingContext
                galleryItem.stickersContext = stickersContext
                galleryItems.append(galleryItem)
                
                if selectedItem.uniqueIdentifier == item.uniqueIdentifier {
                    if let galleryItem = galleryItem as? TGMediaPickerGalleryItem {
                        galleryItem.immediateThumbnailImage = immediateThumbnail
                    }
                    focusItem = galleryItem
                }
            } else if let asset = selectedItem as? TGCameraCapturedVideo {
                let galleryItem: (TGModernGallerySelectableItem & TGModernGalleryEditableItem) = TGMediaPickerGalleryVideoItem(asset: asset)
                galleryItem.selectionContext = selectionContext
                galleryItem.editingContext = editingContext
                galleryItem.stickersContext = stickersContext
                galleryItems.append(galleryItem)
                
                if selectedItem.uniqueIdentifier == item.uniqueIdentifier {
                    if let galleryItem = galleryItem as? TGMediaPickerGalleryItem {
                        galleryItem.immediateThumbnailImage = immediateThumbnail
                    }
                    focusItem = galleryItem
                }
            }
        }
    }
    
    return (galleryItems, focusItem)
}

enum LegacyMediaPickerGallerySource {
    case fetchResult(fetchResult: PHFetchResult<PHAsset>, index: Int, reversed: Bool)
    case selection(item: TGMediaSelectableItem)
}

func presentLegacyMediaPickerGallery(
    context: AccountContext,
    peer: EnginePeer?,
    threadTitle: String?,
    chatLocation: ChatLocation?,
    isScheduledMessages: Bool,
    isActionButtonDone: Bool = false,
    presentationData: PresentationData,
    source: LegacyMediaPickerGallerySource,
    immediateThumbnail: UIImage?,
    selectionContext: TGMediaSelectionContext?,
    editingContext: TGMediaEditingContext,
    asFile: Bool,
    hasSilentPosting: Bool,
    hasSchedule: Bool,
    hasTimer: Bool,
    updateHiddenMedia: @escaping (String?) -> Void,
    initialLayout: ContainerViewLayout?,
    transitionHostView: @escaping () -> UIView?,
    transitionView: @escaping (String) -> UIView?,
    completed: @escaping (TGMediaSelectableItem & TGMediaEditableItem, Bool, Int32?, @escaping () -> Void) -> Void,
    presentSchedulePicker: @escaping (Bool, @escaping (Int32, Bool) -> Void) -> Void,
    presentTimerPicker: @escaping (@escaping (Int32) -> Void) -> Void,
    getCaptionPanelView: @escaping () -> TGCaptionPanelView?,
    present: @escaping (ViewController, Any?) -> Void,
    finishedTransitionIn: @escaping () -> Void,
    willTransitionOut: @escaping () -> Void,
    dismissAll: @escaping () -> Void,
    editCover: @escaping (CGSize, @escaping (UIImage) -> Void) -> Void = { _, _ in }
) -> TGModernGalleryController {
    let reminder = peer?.id == context.account.peerId
    let hasSilentPosting = hasSilentPosting && peer?.id != context.account.peerId
    var hasCoverButton = false
    if case let .channel(channel) = peer, case .broadcast = channel.info {
        hasCoverButton = true
    } else if peer?.id == context.account.peerId {
        hasCoverButton = true
    }
    
    let legacyController = LegacyController(presentation: .custom, theme: presentationData.theme, initialLayout: nil)
    legacyController.statusBar.statusBarStyle = presentationData.theme.rootController.statusBarStyle.style
    
    let paintStickersContext = LegacyPaintStickersContext(context: context)
    paintStickersContext.presentMediaPickerSendActionMenu = makeLegacyMediaPickerSendActionMenuPresenter(context: context, presentationData: presentationData, presentInGlobalOverlay: { [weak legacyController] controller in
        if let legacyController {
            legacyController.presentInGlobalOverlay(controller)
        } else if let mainWindow = context.sharedContext.mainWindow {
            mainWindow.presentInGlobalOverlay(controller)
        } else {
            context.sharedContext.presentGlobalController(controller, nil)
        }
    })
    paintStickersContext.captionPanelView = {
        return getCaptionPanelView()
    }
    paintStickersContext.livePhotoButton = {
        if case .secretChat = peer {
            return nil
        } else if peer == nil {
            return nil
        }
        let livePhotoButton = LivePhotoButton(context: context)
        livePhotoButton.present = present
        return livePhotoButton
    }
    paintStickersContext.photoToolbarView = { backButton, doneButton, solidBackground, hasSendStarsButton in
        return makeMediaPickerPhotoToolbarView(context: context, backButton: backButton, doneButton: doneButton, solidBackground: solidBackground, hasSendStarsButton: hasSendStarsButton)
    }
    paintStickersContext.editCover = { dimensions, completion in
        editCover(dimensions, completion)
    }
    
    let controller = TGModernGalleryController(context: legacyController.context)!
    controller.asyncTransitionIn = true
    legacyController.bind(controller: controller)
    
    let (items, focusItem): ([TGModernGalleryItem], TGModernGalleryItem?)
    switch source {
    case let .fetchResult(fetchResult, index, reversed):
        (items, focusItem) = galleryFetchResultItems(fetchResult: fetchResult, index: index, reversed: reversed, selectionContext: selectionContext, editingContext: editingContext, stickersContext: paintStickersContext, immediateThumbnail: immediateThumbnail, asFile: asFile)
    case let .selection(item):
        (items, focusItem) = gallerySelectionItems(item: item, selectionContext: selectionContext, editingContext: editingContext, stickersContext: paintStickersContext, immediateThumbnail: immediateThumbnail)
    }
    
    let recipientName: String?
    if let threadTitle {
        recipientName = threadTitle
    } else {
        if peer?.id == context.account.peerId {
            recipientName = presentationData.strings.DialogList_SavedMessages
        } else {
            recipientName = peer?.displayTitle(strings: presentationData.strings, displayOrder: presentationData.nameDisplayOrder)
        }
    }
    
    let model = TGMediaPickerGalleryModel(
        context: legacyController.context,
        items: items,
        focus: focusItem,
        selectionContext: selectionContext,
        editingContext: editingContext,
        hasCaptions: true,
        allowCaptionEntities: true,
        hasTimer: hasTimer,
        onlyCrop: false,
        inhibitDocumentCaptions: false,
        hasSelectionPanel: true,
        hasCamera: false,
        recipientName: recipientName,
        isScheduledMessages: isScheduledMessages,
        isActionButtonDone: isActionButtonDone,
        hasCoverButton: hasCoverButton
    )!
    model.stickersContext = paintStickersContext
    controller.model = model
    model.controller = controller
    model.willFinishEditingItem = { item, adjustments, representation, hasChanges in
        if hasChanges {
            editingContext.setAdjustments(adjustments, for: item)
            editingContext.setTemporaryRep(representation, for: item)
        }
        
        if let selectionContext = selectionContext, adjustments != nil, let item = item as? TGMediaSelectableItem {
            selectionContext.setItem(item, selected: true)
        }
    }
    model.didFinishEditingItem = { item, adjustments, result, thumbnail in
        editingContext.setImage(result, thumbnailImage: thumbnail, for: item, synchronous: false)
    }
    model.saveItemCaption = { item, caption in
        editingContext.setCaption(caption, for: item)
        if let selectionContext = selectionContext, let caption = caption, caption.length > 0, let item = item as? TGMediaSelectableItem {
            selectionContext.setItem(item, selected: true)
        }
    }
    model.didFinishRenderingFullSizeImage = { item, result in
        editingContext.setFullSizeImage(result, for: item)
    }
    model.requestAdjustments = { item in
        return editingContext.adjustments(for: item)
    }
    if let selectionContext = selectionContext {
        model.interfaceView.updateSelectionInterface(selectionContext.count(), counterVisible: selectionContext.count() > 0, animated: false)
    }
    controller.transitionHost = {
        return transitionHostView()
    }
    var transitionedIn = false
    // Luckgram specs#106 / #108: actions on the photo before sending (「识别文字」, 「翻译图片」)
    let luckgramActions = LuckgramGalleryHooks.attachPreviewActions?(context) ?? []
    var luckgramCurrent: TGMediaPickerGalleryItem? = focusItem as? TGMediaPickerGalleryItem
    let luckgramStack = UIStackView()
    luckgramStack.axis = .horizontal
    luckgramStack.spacing = 8.0
    let luckgramUpdate = {
        let isPhoto = (luckgramCurrent?.asset as? TGMediaAsset).map { !$0.isVideo } ?? false
        luckgramStack.isHidden = !isPhoto || luckgramActions.isEmpty
    }
    controller.itemFocused = { item in
        if let item = item as? TGMediaPickerGalleryItem, transitionedIn {
            updateHiddenMedia(item.asset.uniqueIdentifier)
        }
        luckgramCurrent = item as? TGMediaPickerGalleryItem
        luckgramUpdate()
    }
    for action in luckgramActions {
        let button = LuckgramClosureButton(type: .system)
        button.setTitle(action.title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = UIFont.boldSystemFont(ofSize: 13.0)
        button.backgroundColor = UIColor(white: 0.0, alpha: 0.6)
        button.layer.cornerRadius = 16.0
        button.widthAnchor.constraint(equalToConstant: max(44.0, button.intrinsicContentSize.width + 24.0)).isActive = true
        button.heightAnchor.constraint(equalToConstant: 32.0).isActive = true
        button.onTap = { [weak controller, weak editingContext, weak selectionContext] in
            guard let item = luckgramCurrent, let asset = item.asset as? TGMediaAsset else {
                return
            }
            luckgramLoadImage(asset, { image in
                guard let image else {
                    return
                }
                action.run(image, { c in
                    controller?.present(c, animated: true)
                }, { newImage in
                    // #108: the new image is sent instead of this photo (as if it had been edited)
                    editingContext?.setImage(newImage, thumbnailImage: luckgramThumbnail(newImage), for: item.asset, synchronous: false)
                    editingContext?.setFullSizeImage(newImage, for: item.asset)
                    selectionContext?.setItem(item.asset, selected: true)
                })
            })
        }
        luckgramStack.addArrangedSubview(button)
    }
    luckgramUpdate()
    controller.beginTransitionIn = { item, itemView in
        if let item = item as? TGMediaPickerGalleryItem {
            if let itemView = itemView as? TGMediaPickerGalleryVideoItemView {
                itemView.setIsCurrent(true)
            }
            
            return transitionView(item.asset.uniqueIdentifier)
        } else {
            return nil
        }
    }
    
    controller.startedTransitionIn = {
        transitionedIn = true
        if let focusItem = focusItem as? TGModernGallerySelectableItem {
            updateHiddenMedia(focusItem.selectableMediaItem().uniqueIdentifier)
        }
    }
    controller.beginTransitionOut = { item, itemView in
        willTransitionOut()
        
        if let item = item as? TGMediaPickerGalleryItem {
            if let itemView = itemView as? TGMediaPickerGalleryVideoItemView {
                itemView.stop()
            }
            return transitionView(item.asset.uniqueIdentifier)
        } else {
            return nil
        }
    }
    controller.finishedTransitionIn = { [weak model, weak controller] _, _ in
        model?.interfaceView.setSelectedItemsModel(model?.selectedItemsModel)
        if let view = controller?.view, !luckgramActions.isEmpty, luckgramStack.superview == nil {
            luckgramStack.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(luckgramStack)
            NSLayoutConstraint.activate([
                luckgramStack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12.0),
                luckgramStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -150.0)
            ])
        }
        
        finishedTransitionIn()
    }
    controller.completedTransitionOut = { [weak legacyController] in
        updateHiddenMedia(nil)
        legacyController?.dismiss()
    }

    model.interfaceView.donePressed = { [weak controller] item in
        if let item = item as? TGMediaPickerGalleryItem {
            completed(item.asset, false, nil, {
                controller?.dismissWhenReady(animated: true)
                dismissAll()
            })
        }
    }
    if !isScheduledMessages && peer != nil {
        model.interfaceView.doneLongPressed = { [weak selectionContext, weak editingContext, weak legacyController, weak model, weak paintStickersContext] item, sourceView in
            if let legacyController = legacyController, let item = item as? TGMediaPickerGalleryItem, let model = model, let selectionContext = selectionContext {
                var effectiveHasSchedule = hasSchedule
                
                if let editingContext = editingContext {
                    if let timer = editingContext.timer(for: item.asset)?.intValue, timer > 0 {
                        effectiveHasSchedule = false
                    }
                    for item in selectionContext.selectedItems() {
                        if let editableItem = item as? TGMediaEditableItem, let timer = editingContext.timer(for: editableItem)?.intValue, timer > 0 {
                            effectiveHasSchedule = false
                            break
                        }
                    }
                }
                
                let sendWhenOnlineAvailable: Signal<Bool, NoError>
                if let peer {
                    if case .secretChat = peer {
                        effectiveHasSchedule = false
                    }
                    sendWhenOnlineAvailable = context.account.viewTracker.peerView(peer.id)
                    |> take(1)
                    |> map { peerView -> Bool in
                        guard let peer = peerViewMainPeer(peerView) else {
                            return false
                        }
                        var sendWhenOnlineAvailable = false
                        if let presence = peerView.peerPresences[peer.id] as? TelegramUserPresence, case let .present(until) = presence.status {
                            let currentTime = Int32(CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970)
                            if currentTime > until {
                                sendWhenOnlineAvailable = true
                            }
                        }
                        if peer.id.namespace == Namespaces.Peer.CloudUser && peer.id.id._internalGetInt64Value() == 777000 {
                            sendWhenOnlineAvailable = false
                        }
                        return sendWhenOnlineAvailable
                    }
                } else {
                    sendWhenOnlineAvailable = .single(false)
                }
                
                let _ = (sendWhenOnlineAvailable
                |> take(1)
                |> deliverOnMainQueue).start(next: { [model] sendWhenOnlineAvailable in
                    let dismissImpl = { [weak model] in
                        model?.dismiss(true, false)
                        dismissAll()
                    }
                    let send = {
                        completed(item.asset, false, nil, {
                            dismissImpl()
                        })
                    }
                    let sendSilently = { [weak model] in
                        model?.interfaceView.onDismiss()
                        
                        completed(item.asset, true, nil, {
                            dismissImpl()
                        })
                    }
                    let sendWhenOnline = {
                        completed(item.asset, false, scheduleWhenOnlineTimestamp, {
                            dismissImpl()
                        })
                    }
                    let schedule = {
                        presentSchedulePicker(true, { time, silentPosting in
                            completed(item.asset, silentPosting, time, {
                                dismissImpl()
                            })
                        })
                    }
                    let sendWithTimer = {
                        presentTimerPicker { time in
                            var items = selectionContext.selectedItems() ?? []
                            items.append(item.asset as Any)
                            
                            for case let item as TGMediaEditableItem in items {
                                editingContext?.setTimer(time as NSNumber, for: item)
                            }
                            
                            completed(item.asset, false, nil, {
                                dismissImpl()
                            })
                        }
                    }

                    if let sourceView, let paintStickersContext, paintStickersContext.presentMediaPickerSendActionMenu?(sourceView, hasSilentPosting, sendWhenOnlineAvailable && effectiveHasSchedule, effectiveHasSchedule, reminder, hasTimer, sendSilently, sendWhenOnline, schedule, sendWithTimer) == true {
                        let hapticFeedback = HapticFeedback()
                        hapticFeedback.impact()
                        return
                    }

                    let legacySheetController = LegacyController(presentation: .custom, theme: presentationData.theme, initialLayout: nil)
                    let sheetController = TGMediaPickerSendActionSheetController(context: legacyController.context, isDark: true, sendButtonFrame: model.interfaceView.doneButtonFrame, canSendSilently: hasSilentPosting, canSendWhenOnline: sendWhenOnlineAvailable && effectiveHasSchedule, canSchedule: effectiveHasSchedule, reminder: reminder, hasTimer: hasTimer)
                    sheetController.send = send
                    sheetController.sendSilently = sendSilently
                    sheetController.sendWhenOnline = sendWhenOnline
                    sheetController.schedule = schedule
                    sheetController.sendWithTimer = sendWithTimer
                    sheetController.customDismissBlock = { [weak legacySheetController] in
                        legacySheetController?.dismiss()
                    }
                    legacySheetController.bind(controller: sheetController)
                    present(legacySheetController, nil)
                    
                    let hapticFeedback = HapticFeedback()
                    hapticFeedback.impact()
                })
            }
        }
    }
    model.interfaceView.setThumbnailSignalForItem { item in
        let imageSignal = SSignal(generator: { subscriber in
            var asset: PHAsset?
            if let item = item as? TGCameraCapturedVideo, item.originalAsset != nil {
                asset = item.originalAsset.backingAsset
            } else if let item = item as? TGMediaAsset {
                asset = item.backingAsset
            }
            var disposable: Disposable?
            if let asset = asset {
                let scale = min(2.0, UIScreenScale)
                disposable = assetImage(asset: asset, targetSize: CGSize(width: 128.0 * scale, height: 128.0 * scale), exact: false).start(next: { image in
                    subscriber.putNext(image)
                }, completed: {
                    subscriber.putCompletion()
                })
            } else {
                subscriber.putCompletion()
            }
            return SBlockDisposable(block: {
                disposable?.dispose()
            })
        })
        if let item = item as? TGMediaEditableItem {
            return editingContext.thumbnailImageSignal(for: item).map(toSignal: { result in
                if let result = result {
                    return SSignal.single(result)
                } else {
                    return imageSignal
                }
            })
        } else {
            return imageSignal
        }
    }
    present(legacyController, nil)
    
    return controller
}

// MARK: - Luckgram specs#106 / #108

private final class LuckgramClosureButton: UIButton {
    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.addTarget(self, action: #selector(self.tapped), for: .touchUpInside)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func tapped() {
        self.onTap?()
    }
}

/// The photo of an asset (up to 2048 px), from iCloud if needed; main queue.
private func luckgramLoadImage(_ asset: TGMediaAsset, _ done: @escaping (UIImage?) -> Void) {
    guard let backing = asset.backingAsset else {
        done(nil)
        return
    }
    let options = PHImageRequestOptions()
    options.isNetworkAccessAllowed = true
    options.deliveryMode = .highQualityFormat
    options.resizeMode = .fast
    PHImageManager.default().requestImage(for: backing, targetSize: CGSize(width: 2048.0, height: 2048.0), contentMode: .aspectFit, options: options, resultHandler: { image, _ in
        DispatchQueue.main.async {
            done(image)
        }
    })
}

private func luckgramThumbnail(_ image: UIImage) -> UIImage {
    let side: CGFloat = 256.0
    let scale = min(1.0, side / max(image.size.width, image.size.height))
    let size = CGSize(width: max(1.0, floor(image.size.width * scale)), height: max(1.0, floor(image.size.height * scale)))
    return UIGraphicsImageRenderer(size: size).image { _ in
        image.draw(in: CGRect(origin: .zero, size: size))
    }
}
