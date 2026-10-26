import Foundation
import UIKit
import Display
import AsyncDisplayKit
import ComponentFlow
import SwiftSignalKit
import ViewControllerComponent
import ComponentDisplayAdapters
import TelegramPresentationData
import AccountContext
import TelegramCore
import MultilineTextComponent

/// Maximum cache size. Luckgram 08 (cache): offers 1 / 2 / 5 / 10 / 20 / 50 GB / no limit as a
/// value row that opens a menu (seven labels do not fit on the former slider without overlapping).
final class StorageKeepSizeComponent: Component {
    let theme: PresentationTheme
    let strings: PresentationStrings
    let value: Int32
    let action: (StoragePeerTypeItemComponent.View) -> Void
    
    init(
        theme: PresentationTheme,
        strings: PresentationStrings,
        value: Int32,
        action: @escaping (StoragePeerTypeItemComponent.View) -> Void
    ) {
        self.theme = theme
        self.strings = strings
        self.value = value
        self.action = action
    }
    
    static func ==(lhs: StorageKeepSizeComponent, rhs: StorageKeepSizeComponent) -> Bool {
        if lhs.theme !== rhs.theme {
            return false
        }
        if lhs.strings !== rhs.strings {
            return false
        }
        if lhs.value != rhs.value {
            return false
        }
        return true
    }
    
    class View: UIView {
        private let item = ComponentView<Empty>()
        
        private var component: StorageKeepSizeComponent?
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            
            self.clipsToBounds = true
            self.layer.cornerRadius = 26.0
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        func update(component: StorageKeepSizeComponent, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
            let themeUpdated = self.component?.theme !== component.theme
            
            self.component = component
            
            if themeUpdated {
                self.backgroundColor = component.theme.list.itemBlocksBackgroundColor
            }
            
            let itemSize = self.item.update(
                transition: transition,
                component: AnyComponent(StoragePeerTypeItemComponent(
                    theme: component.theme,
                    icon: PresentationResourcesSettings.storageUsage ?? UIImage(),
                    title: LuckgramCacheStrings.cacheLimitTitle(component.strings),
                    subtitle: nil,
                    value: LuckgramCacheStrings.cacheLimit(component.strings, gigabytes: LuckgramCacheStrings.normalizedCacheLimit(component.value)),
                    hasNext: false,
                    action: { [weak self] sourceView in
                        self?.component?.action(sourceView)
                    }
                )),
                environment: {},
                containerSize: availableSize
            )
            if let itemView = self.item.view {
                if itemView.superview == nil {
                    self.addSubview(itemView)
                }
                transition.setFrame(view: itemView, frame: CGRect(origin: CGPoint(), size: itemSize))
            }
            
            return CGSize(width: availableSize.width, height: itemSize.height)
        }
    }
    
    func makeView() -> View {
        return View(frame: CGRect())
    }
    
    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, state: state, environment: environment, transition: transition)
    }
}
