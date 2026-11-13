import UIKit

/// Luckgram specs#102: the 「+」 panel colors, one table for both apps. Keep the values identical to Android
/// (`org.telegram.luckgram.compactinput.LuckgramPlusPanelColors`). ARGB hex.
///
/// | role                | light       | dark        |
/// |---------------------|-------------|-------------|
/// | icon                | `FFFFFFFF`  | `FFFFFFFF`  |
/// | title               | `A6000000`  | `B3FFFFFF`  |
/// | page dot (current)  | `FF000000`  | `FFFFFFFF`  |
/// | page dot (other)    | `40000000`  | `40FFFFFF`  |
/// | dimmed cell opacity | 0.4         | 0.4         |
///
/// specs#147: every entry has its own icon square, a top-to-bottom gradient (same in light and dark):
///
/// | entry         | top        | bottom     |
/// |---------------|------------|------------|
/// | gallery       | `FF5EB5F7` | `FF2A82E4` |
/// | camera        | `FFFF7A85` | `FFE8415A` |
/// | file          | `FF8C9EFF` | `FF5667E8` |
/// | location      | `FF5FD97A` | `FF25A84A` |
/// | contact       | `FFFFB55C` | `FFF5881F` |
/// | poll          | `FFFFD45C` | `FFF2A900` |
/// | quick replies | `FF4FD6C8` | `FF16A89B` |
/// | voice input   | `FFC18CFF` | `FF8E4FE8` |
/// | AI writing    | `FFF58AE0` | `FFB04CF0` |
/// | translate     | `FF5CCBF5` | `FF1E9BD6` |
public enum LuckgramPlusPanelColors {
    public static let dimmedAlpha: CGFloat = 0.4

    public static func icon(dark: Bool) -> UIColor { return color(0xFFFFFFFF) }
    public static func title(dark: Bool) -> UIColor { return color(dark ? 0xB3FFFFFF : 0xA6000000) }

    /// Top and bottom colors of the entry's icon square.
    public static func square(_ action: LuckgramPlusAction) -> (top: UIColor, bottom: UIColor) {
        let pair: (UInt32, UInt32)
        switch action {
        case .emoji: pair = (0xFFFF8FB8, 0xFFE8478A)
        case .gallery: pair = (0xFF5EB5F7, 0xFF2A82E4)
        case .camera: pair = (0xFFFF7A85, 0xFFE8415A)
        case .file: pair = (0xFF8C9EFF, 0xFF5667E8)
        case .location: pair = (0xFF5FD97A, 0xFF25A84A)
        case .contact: pair = (0xFFFFB55C, 0xFFF5881F)
        case .poll: pair = (0xFFFFD45C, 0xFFF2A900)
        case .quickReplies: pair = (0xFF4FD6C8, 0xFF16A89B)
        case .dictation: pair = (0xFFC18CFF, 0xFF8E4FE8)
        case .aiWriting: pair = (0xFFF58AE0, 0xFFB04CF0)
        case .translate: pair = (0xFF5CCBF5, 0xFF1E9BD6)
        }
        return (color(pair.0), color(pair.1))
    }
    public static func dotCurrent(dark: Bool) -> UIColor { return color(dark ? 0xFFFFFFFF : 0xFF000000) }
    public static func dotOther(dark: Bool) -> UIColor { return color(dark ? 0x40FFFFFF : 0x40000000) }

    private static func color(_ argb: UInt32) -> UIColor {
        return UIColor(
            red: CGFloat((argb >> 16) & 0xFF) / 255.0,
            green: CGFloat((argb >> 8) & 0xFF) / 255.0,
            blue: CGFloat(argb & 0xFF) / 255.0,
            alpha: CGFloat((argb >> 24) & 0xFF) / 255.0
        )
    }
}
