import Foundation

/// specs#207: the pinned "Luckgram AI" row of the chat list is a header panel above the list, so on
/// iOS 26 the list scrolled under it and the row covered the first chats. It is hidden once the list
/// is scrolled down and shown again back at the top. Two thresholds, so the row does not flicker
/// while the header height changes under the finger.
///
/// Pure (Foundation only) so it is unit tested on its own.
public enum LuckgramAIRowScroll {
    /// Scrolled further than this (points from the top) → hidden.
    public static let hideAfter: Double = 24.0
    /// Back within this of the top → shown.
    public static let showWithin: Double = 4.0

    /// Whether the row is hidden at `offset` (0 = list at the top, positive = scrolled down).
    public static func hidden(wasHidden: Bool, offset: Double) -> Bool {
        if wasHidden {
            return offset > showWithin
        }
        return offset > hideAfter
    }
}
