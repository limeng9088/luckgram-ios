import Foundation
import UIKit
import TelegramPresentationData

/// Pull-to-refresh for the Square feed, laid over the top of the list (the list itself is never
/// emptied). Same behaviour as SquareRefreshView on Android: while the list is pulled down past
/// its top a round indicator comes out and fills its arc; past the threshold a release starts the
/// refresh and the arc spins in place; when the refresh ends the indicator shrinks away and a
/// small pill says what happened ("3 new posts" / "You're up to date") for a moment.
final class LuckgramSquareRefreshView: UIView {
    static let height: CGFloat = 76.0
    private static let size: CGFloat = 36.0
    /// Resting place of the indicator while refreshing, from the top of this view.
    private static let rest: CGFloat = 12.0
    private static let pillSeconds: Double = 1.3

    private let circle = UIView()
    private let arc = CAShapeLayer()
    private let pill = UIView()
    private let pillLabel = UILabel()
    private var pillHide: DispatchWorkItem?
    /// Bumped by every state change, so the end of an older animation does not undo a newer state.
    private var generation = 0
    private(set) var isRefreshing = false

    init(theme: PresentationTheme) {
        super.init(frame: CGRect())
        self.isUserInteractionEnabled = false
        self.clipsToBounds = true

        let size = LuckgramSquareRefreshView.size
        self.circle.bounds = CGRect(x: 0.0, y: 0.0, width: size, height: size)
        self.circle.layer.cornerRadius = size / 2.0
        self.circle.layer.shadowColor = UIColor.black.cgColor
        self.circle.layer.shadowOpacity = 0.16
        self.circle.layer.shadowRadius = 4.0
        self.circle.layer.shadowOffset = CGSize(width: 0.0, height: 1.0)
        self.circle.alpha = 0.0
        self.addSubview(self.circle)

        self.arc.frame = self.circle.bounds
        self.arc.path = UIBezierPath(arcCenter: CGPoint(x: size / 2.0, y: size / 2.0), radius: 9.0, startAngle: -CGFloat.pi / 2.0, endAngle: CGFloat.pi * 1.5, clockwise: true).cgPath
        self.arc.fillColor = UIColor.clear.cgColor
        self.arc.lineWidth = 2.5
        self.arc.lineCap = .round
        self.arc.strokeEnd = 0.0
        self.circle.layer.addSublayer(self.arc)

        self.pill.layer.cornerRadius = 13.0
        self.pill.alpha = 0.0
        self.pillLabel.font = UIFont.systemFont(ofSize: 12.0, weight: .semibold)
        self.pillLabel.textAlignment = .center
        self.pill.addSubview(self.pillLabel)
        self.addSubview(self.pill)

        self.updateTheme(theme)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateTheme(_ theme: PresentationTheme) {
        self.circle.backgroundColor = theme.list.itemBlocksBackgroundColor
        self.arc.strokeColor = theme.list.itemAccentColor.cgColor
        self.pill.backgroundColor = theme.list.itemAccentColor
        self.pillLabel.textColor = theme.list.itemCheckColors.foregroundColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // above the top edge until pulled out
        self.circle.center = CGPoint(x: self.bounds.midX, y: -LuckgramSquareRefreshView.size / 2.0)
        self.layoutPill()
    }

    private func layoutPill() {
        let text = self.pillLabel.sizeThatFits(CGSize(width: max(0.0, self.bounds.width - 60.0), height: 30.0))
        let width = min(max(0.0, self.bounds.width - 32.0), ceil(text.width) + 24.0)
        self.pill.bounds = CGRect(x: 0.0, y: 0.0, width: width, height: 26.0)
        self.pill.center = CGPoint(x: self.bounds.midX, y: 6.0 + 13.0)
        self.pillLabel.frame = self.pill.bounds
    }

    private var travel: CGFloat {
        return LuckgramSquareRefreshView.size + LuckgramSquareRefreshView.rest
    }

    private func setArc(_ strokeEnd: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        self.arc.strokeEnd = strokeEnd
        CATransaction.commit()
    }

    /// The list is pulled down past its top; `progress` 1 = far enough to refresh on release.
    func setPull(_ progress: CGFloat) {
        if self.isRefreshing {
            return
        }
        let p = max(0.0, min(1.0, progress))
        self.generation += 1
        if p > 0.0 {
            self.hidePill(animated: false)
        }
        self.circle.layer.removeAllAnimations()
        self.arc.removeAnimation(forKey: "spin")
        self.circle.alpha = min(1.0, p * 1.6)
        self.circle.transform = CGAffineTransform(translationX: 0.0, y: p * self.travel)
        self.setArc(0.06 + 0.84 * p)
        self.arc.setAffineTransform(CGAffineTransform(rotationAngle: p * CGFloat.pi * 1.5))
    }

    /// A refresh is running: the indicator settles at its resting place and spins.
    func showRefreshing() {
        self.generation += 1
        self.hidePill(animated: false)
        let wasHidden = self.circle.alpha < 0.01
        self.isRefreshing = true
        self.circle.layer.removeAllAnimations()
        let rest = CGAffineTransform(translationX: 0.0, y: self.travel)
        if wasHidden {
            // started without a pull (the open tab tapped again): pop in at the resting place
            self.circle.transform = rest.scaledBy(x: 0.6, y: 0.6)
        }
        self.setArc(0.7)
        self.arc.setAffineTransform(.identity)
        self.startSpin()
        UIView.animate(withDuration: 0.2, delay: 0.0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
            self.circle.alpha = 1.0
            self.circle.transform = rest
        }, completion: nil)
    }

    private func startSpin() {
        if self.arc.animation(forKey: "spin") != nil {
            return
        }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0.0
        spin.toValue = Double.pi * 2.0
        spin.duration = 0.8
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        self.arc.add(spin, forKey: "spin")
    }

    /// The refresh ended (or there is none for the list now shown). `result` is shown in the pill
    /// for a moment; nil for nothing.
    func finish(result: String?) {
        self.generation += 1
        let generation = self.generation
        let wasShown = self.circle.alpha > 0.01
        self.isRefreshing = false
        if wasShown {
            UIView.animate(withDuration: 0.16, delay: 0.0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
                self.circle.alpha = 0.0
                self.circle.transform = CGAffineTransform(translationX: 0.0, y: self.travel).scaledBy(x: 0.1, y: 0.1)
            }, completion: { _ in
                guard generation == self.generation else {
                    return
                }
                self.arc.removeAnimation(forKey: "spin")
                self.circle.transform = .identity
            })
        } else {
            self.arc.removeAnimation(forKey: "spin")
        }
        if let result {
            self.showPill(result, delay: wasShown ? 0.12 : 0.0)
        }
    }

    private func showPill(_ text: String, delay: Double) {
        self.pillHide?.cancel()
        self.pillLabel.text = text
        self.layoutPill()
        self.pill.layer.removeAllAnimations()
        self.pill.alpha = 0.0
        self.pill.transform = CGAffineTransform(translationX: 0.0, y: -10.0).scaledBy(x: 0.92, y: 0.92)
        UIView.animate(withDuration: 0.22, delay: delay, options: [.curveEaseOut], animations: {
            self.pill.alpha = 1.0
            self.pill.transform = .identity
        }, completion: nil)
        UIAccessibility.post(notification: .announcement, argument: text)
        let hide = DispatchWorkItem { [weak self] in
            self?.hidePill(animated: true)
        }
        self.pillHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + LuckgramSquareRefreshView.pillSeconds, execute: hide)
    }

    private func hidePill(animated: Bool) {
        self.pillHide?.cancel()
        self.pillHide = nil
        if self.pill.alpha < 0.01 {
            return
        }
        if animated {
            UIView.animate(withDuration: 0.22, delay: 0.0, options: [.curveEaseOut, .beginFromCurrentState], animations: {
                self.pill.alpha = 0.0
                self.pill.transform = CGAffineTransform(translationX: 0.0, y: -8.0)
            }, completion: nil)
        } else {
            self.pill.layer.removeAllAnimations()
            self.pill.alpha = 0.0
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // layer animations are dropped while the view is off screen
        if self.window != nil && self.isRefreshing {
            self.startSpin()
        }
    }
}
