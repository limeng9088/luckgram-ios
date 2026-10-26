// Luckgram — private notes (spec 05).
// Licensed under GNU GPL v. 2 or later.

import Foundation
import UIKit
import Display
import ComponentFlow
import TelegramPresentationData
import AppBundle

/// Thin, collapsible bar shown in the chat header panels (below the pinned message bar) when the
/// peer has a private note. Collapsed: header + first line. Expanded: header + full note + Edit.
public final class LuckgramUserNoteHeaderPanelComponent: Component {
    public let theme: PresentationTheme
    public let strings: LuckgramUserNotesStrings
    public let text: String
    public let isExpanded: Bool
    public let toggleExpanded: () -> Void
    public let edit: () -> Void

    public init(theme: PresentationTheme, strings: LuckgramUserNotesStrings, text: String, isExpanded: Bool, toggleExpanded: @escaping () -> Void, edit: @escaping () -> Void) {
        self.theme = theme
        self.strings = strings
        self.text = text
        self.isExpanded = isExpanded
        self.toggleExpanded = toggleExpanded
        self.edit = edit
    }

    public static func ==(lhs: LuckgramUserNoteHeaderPanelComponent, rhs: LuckgramUserNoteHeaderPanelComponent) -> Bool {
        if lhs.theme !== rhs.theme {
            return false
        }
        if lhs.strings.isChinese != rhs.strings.isChinese {
            return false
        }
        if lhs.text != rhs.text {
            return false
        }
        if lhs.isExpanded != rhs.isExpanded {
            return false
        }
        return true
    }

    public final class View: UIView {
        private let lineView = UIView()
        private let titleLabel = UILabel()
        private let textLabel = UILabel()
        private let editButton = UIButton(type: .system)
        private let arrowButton = UIButton(type: .custom)
        private let backgroundButton = UIButton(type: .custom)

        private var component: LuckgramUserNoteHeaderPanelComponent?

        public override init(frame: CGRect) {
            super.init(frame: frame)

            self.clipsToBounds = true
            self.addSubview(self.backgroundButton)
            self.lineView.layer.cornerRadius = 1.0
            self.addSubview(self.lineView)

            self.titleLabel.font = Font.medium(15.0)
            self.titleLabel.numberOfLines = 1
            self.titleLabel.lineBreakMode = .byTruncatingTail
            self.addSubview(self.titleLabel)

            self.textLabel.font = Font.regular(15.0)
            self.textLabel.lineBreakMode = .byTruncatingTail
            self.addSubview(self.textLabel)

            self.editButton.titleLabel?.font = Font.medium(15.0)
            self.editButton.contentHorizontalAlignment = .left
            self.addSubview(self.editButton)

            self.addSubview(self.arrowButton)

            self.backgroundButton.addTarget(self, action: #selector(self.backgroundPressed), for: .touchUpInside)
            self.editButton.addTarget(self, action: #selector(self.editPressed), for: .touchUpInside)
            self.arrowButton.addTarget(self, action: #selector(self.arrowPressed), for: .touchUpInside)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        @objc private func backgroundPressed() {
            guard let component = self.component else {
                return
            }
            if component.isExpanded {
                component.edit()
            } else {
                component.toggleExpanded()
            }
        }

        @objc private func editPressed() {
            self.component?.edit()
        }

        @objc private func arrowPressed() {
            self.component?.toggleExpanded()
        }

        func update(component: LuckgramUserNoteHeaderPanelComponent, availableSize: CGSize, transition: ComponentTransition) -> CGSize {
            let themeUpdated = self.component?.theme !== component.theme
            self.component = component

            let accentColor = component.theme.chat.inputPanel.panelControlColor
            let textColor = component.theme.chat.inputPanel.primaryTextColor
            if themeUpdated {
                self.lineView.backgroundColor = accentColor
                self.titleLabel.textColor = accentColor
                self.textLabel.textColor = textColor
                self.editButton.setTitleColor(accentColor, for: .normal)
                self.arrowButton.setImage(generateTintedImage(image: UIImage(bundleImageName: "Item List/DisclosureArrow"), color: accentColor), for: .normal)
            }

            self.titleLabel.text = component.strings.barTitle
            self.editButton.setTitle(component.strings.edit, for: .normal)
            if component.isExpanded {
                self.textLabel.numberOfLines = 12
                self.textLabel.text = component.text
            } else {
                self.textLabel.numberOfLines = 1
                self.textLabel.text = LuckgramUserNotesStore.firstLine(component.text)
            }
            self.arrowButton.accessibilityLabel = component.isExpanded ? component.strings.collapse : component.strings.expand
            self.backgroundButton.accessibilityLabel = component.strings.barTitle
            self.backgroundButton.accessibilityValue = self.textLabel.text

            let leftInset: CGFloat = 22.0
            let arrowWidth: CGFloat = 44.0
            let topInset: CGFloat = 7.0
            let textWidth = max(1.0, availableSize.width - leftInset - arrowWidth)

            let titleSize = self.titleLabel.sizeThatFits(CGSize(width: textWidth, height: 100.0))
            let titleFrame = CGRect(origin: CGPoint(x: leftInset, y: topInset), size: CGSize(width: textWidth, height: ceil(titleSize.height)))
            let textSize = self.textLabel.sizeThatFits(CGSize(width: textWidth, height: 10000.0))
            let textFrame = CGRect(origin: CGPoint(x: leftInset, y: titleFrame.maxY + 1.0), size: CGSize(width: textWidth, height: ceil(textSize.height)))

            var height = textFrame.maxY + topInset
            if component.isExpanded {
                let editFrame = CGRect(origin: CGPoint(x: leftInset, y: textFrame.maxY + 4.0), size: CGSize(width: min(textWidth, 120.0), height: 28.0))
                self.editButton.isHidden = false
                transition.setFrame(view: self.editButton, frame: editFrame)
                height = editFrame.maxY + 4.0
            } else {
                self.editButton.isHidden = true
            }
            height = max(48.0, height)

            transition.setFrame(view: self.titleLabel, frame: titleFrame)
            transition.setFrame(view: self.textLabel, frame: textFrame)
            transition.setFrame(view: self.lineView, frame: CGRect(origin: CGPoint(x: 12.0, y: 8.0), size: CGSize(width: 2.0, height: height - 16.0)))
            transition.setFrame(view: self.arrowButton, frame: CGRect(origin: CGPoint(x: availableSize.width - arrowWidth, y: 2.0), size: CGSize(width: arrowWidth, height: 44.0)))
            // Disclosure arrow points down when collapsed, up when expanded.
            self.arrowButton.transform = CGAffineTransform(rotationAngle: component.isExpanded ? -CGFloat.pi / 2.0 : CGFloat.pi / 2.0)
            transition.setFrame(view: self.backgroundButton, frame: CGRect(origin: CGPoint(), size: CGSize(width: availableSize.width, height: height)))

            return CGSize(width: availableSize.width, height: height)
        }
    }

    public func makeView() -> View {
        return View(frame: CGRect())
    }

    public func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<Empty>, transition: ComponentTransition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, transition: transition)
    }
}
