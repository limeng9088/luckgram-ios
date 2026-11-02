import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramPresentationData
import ItemListUI
import PresentationDataUtils
import AccountContext

/// Spec 27: the Discover tab (third main tab). Lists the `LuckgramDiscoverEntries` whose switch is
/// on (Square, People Nearby), each with an icon, title, one-line description and a chevron; shows
/// "暂时没有可用的功能" when none is on. The rows follow the switches live.
public enum LuckgramDiscover {
    public static var title: String { LuckgramStrings.pick("发现", "Discover") }
    public static var emptyText: String { LuckgramStrings.pick("暂时没有可用的功能", "No features available right now") }

    /// Outline compass when unselected, filled when selected (tinted with the accent colour by the tab bar).
    static func tabImage(selected: Bool) -> UIImage? {
        let configuration = UIImage.SymbolConfiguration(pointSize: 22.0, weight: .regular)
        return UIImage(systemName: selected ? "safari.fill" : "safari", withConfiguration: configuration)?.withRenderingMode(.alwaysTemplate)
    }

    /// A settings-style row icon: white glyph on a rounded gradient square.
    static func rowIcon(_ entry: LuckgramDiscoverEntry) -> UIImage? {
        let glyph = UIImage(bundleImageName: entry.iconName)
        let size = CGSize(width: 30.0, height: 30.0)
        return generateImage(size, rotatedContext: { size, context in
            let bounds = CGRect(origin: CGPoint(), size: size)
            context.clear(bounds)
            context.addPath(UIBezierPath(roundedRect: bounds, cornerRadius: 8.0).cgPath)
            context.clip()
            let colors = [entry.colorTop.cgColor, entry.colorBottom.cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0.0, 1.0]) {
                context.drawLinearGradient(gradient, start: CGPoint(x: 0.0, y: 0.0), end: CGPoint(x: 0.0, y: size.height), options: [])
            }
            if let glyph, let tinted = generateTintedImage(image: glyph, color: .white), let cgImage = tinted.cgImage {
                let glyphSize = CGSize(width: 22.0, height: 22.0)
                let rect = CGRect(x: (size.width - glyphSize.width) / 2.0, y: (size.height - glyphSize.height) / 2.0, width: glyphSize.width, height: glyphSize.height)
                context.draw(cgImage, in: rect)
            }
        })
    }
}

private final class LuckgramDiscoverArguments {
    let open: (LuckgramDiscoverEntry) -> Void

    init(open: @escaping (LuckgramDiscoverEntry) -> Void) {
        self.open = open
    }
}

private enum LuckgramDiscoverListEntry: ItemListNodeEntry {
    case entry(index: Int, featureKey: String, title: String, subtitle: String)

    var section: ItemListSectionId {
        return 0
    }

    var stableId: String {
        switch self {
        case let .entry(_, featureKey, _, _):
            return featureKey
        }
    }

    static func <(lhs: LuckgramDiscoverListEntry, rhs: LuckgramDiscoverListEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.entry(a, _, _, _), .entry(b, _, _, _)):
            return a < b
        }
    }

    static func ==(lhs: LuckgramDiscoverListEntry, rhs: LuckgramDiscoverListEntry) -> Bool {
        switch (lhs, rhs) {
        case let (.entry(a1, a2, a3, a4), .entry(b1, b2, b3, b4)):
            return a1 == b1 && a2 == b2 && a3 == b3 && a4 == b4
        }
    }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! LuckgramDiscoverArguments
        switch self {
        case let .entry(_, featureKey, title, subtitle):
            let entry = LuckgramDiscoverEntries.all.first(where: { $0.featureKey == featureKey })
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, icon: entry.flatMap { LuckgramDiscover.rowIcon($0) }, title: title, label: subtitle, labelStyle: .multilineDetailText, sectionId: self.section, style: .blocks, action: {
                if let entry {
                    arguments.open(entry)
                }
            })
        }
    }
}

/// The Discover tab controller (`TelegramRootController` puts it third, after Chats and Contacts).
public func luckgramDiscoverController(context: AccountContext) -> ViewController {
    var pushImpl: ((ViewController) -> Void)?

    let arguments = LuckgramDiscoverArguments(open: { entry in
        guard entry.isEnabled() else {
            return
        }
        pushImpl?(entry.make(context))
    })

    let signal = combineLatest(queue: .mainQueue(), context.sharedContext.presentationData, LuckgramDiscoverEntries.enabled())
    |> map { presentationData, entries -> (ItemListControllerState, (ItemListNodeState, Any)) in
        LuckgramStrings.appLanguageCode = presentationData.strings.primaryComponent.languageCode
        var listEntries: [LuckgramDiscoverListEntry] = []
        for (index, entry) in entries.enumerated() {
            listEntries.append(.entry(index: index, featureKey: entry.featureKey, title: entry.title(), subtitle: entry.subtitle()))
        }
        let controllerState = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(LuckgramDiscover.title), leftNavigationButton: nil, rightNavigationButton: nil, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let listState = ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: listEntries, style: .blocks, emptyStateItem: listEntries.isEmpty ? ItemListTextEmptyStateItem(text: LuckgramDiscover.emptyText) : nil, animateChanges: true)
        return (controllerState, (listState, arguments))
    }

    let tabBarItem: Signal<ItemListControllerTabBarItem, NoError> = context.sharedContext.presentationData
    |> map { presentationData -> ItemListControllerTabBarItem in
        LuckgramStrings.appLanguageCode = presentationData.strings.primaryComponent.languageCode
        return ItemListControllerTabBarItem(title: LuckgramDiscover.title, image: LuckgramDiscover.tabImage(selected: false), selectedImage: LuckgramDiscover.tabImage(selected: true))
    }

    let controller = ItemListController(context: context, state: signal, tabBarItem: tabBarItem)
    pushImpl = { [weak controller] c in
        (controller?.navigationController as? NavigationController)?.pushViewController(c)
    }
    return controller
}
