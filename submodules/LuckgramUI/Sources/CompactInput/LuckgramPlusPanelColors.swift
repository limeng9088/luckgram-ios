import UIKit

/// Luckgram specs#102: the 「+」 panel colors, one table for both apps. Keep the values identical to Android
/// (`org.telegram.luckgram.compactinput.LuckgramPlusPanelColors`). ARGB hex.
///
/// | role                | light       | dark        |
/// |---------------------|-------------|-------------|
/// | icon                | `FF000000`  | `FFFFFFFF`  |
/// | icon square         | `14000000`  | `29FFFFFF`  |
/// | title               | `66000000`  | `7AFFFFFF`  |
/// | page dot (current)  | `FF000000`  | `FFFFFFFF`  |
/// | page dot (other)    | `40000000`  | `40FFFFFF`  |
/// | dimmed cell opacity | 0.4         | 0.4         |
public enum LuckgramPlusPanelColors {
    public static let dimmedAlpha: CGFloat = 0.4

    public static func icon(dark: Bool) -> UIColor { return color(dark ? 0xFFFFFFFF : 0xFF000000) }
    public static func square(dark: Bool) -> UIColor { return color(dark ? 0x29FFFFFF : 0x14000000) }
    public static func title(dark: Bool) -> UIColor { return color(dark ? 0x7AFFFFFF : 0x66000000) }
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
