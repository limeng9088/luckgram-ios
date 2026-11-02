import Foundation
import UIKit
import Display
import SwiftSignalKit
import AccountContext
import LuckgramDiscover

/// The rows of the Discover tab (spec 27: 26 Square, 25 People Nearby, ...). Each entry is shown
/// while its remote-aware switch is on. To add one, append to `all` — `luckgramDiscoverController`
/// only renders this list. (Before 27 they sat at the top of Contacts.)
public struct LuckgramDiscoverEntry {
    public let featureKey: String
    public let title: () -> String
    /// One line under the title on the Discover tab.
    public let subtitle: () -> String
    /// Bundle image name used for the row icon.
    public let iconName: String
    /// Row icon background gradient (same colours as Android `DiscoverEntries`).
    public let colorTop: UIColor
    public let colorBottom: UIColor
    public let isEnabled: () -> Bool
    public let make: (AccountContext) -> ViewController
}

public enum LuckgramDiscoverEntries {
    public static let all: [LuckgramDiscoverEntry] = [
        LuckgramDiscoverEntry(
            featureKey: SquareLogic.featureKey,
            title: { LuckgramSquare.texts.title },
            subtitle: { LuckgramStrings.pick("看看大家在分享什么", "Posts from people and channels") },
            iconName: "Chat/Context Menu/Channels",
            colorTop: UIColor(rgb: 0x5AC8FA),
            colorBottom: UIColor(rgb: 0x2F8BE6),
            isEnabled: { LuckgramSquare.isFeatureEnabled },
            make: { luckgramSquareController(context: $0) }
        ),
        LuckgramDiscoverEntry(
            featureKey: NearbyLogic.featureKey,
            title: { NearbyLogic.Texts(zh: LuckgramStrings.isChinese).title },
            subtitle: { LuckgramStrings.pick("发现你周围的人和群组", "Find people and groups around you") },
            iconName: "Chat/Attach Menu/Location",
            colorTop: UIColor(rgb: 0xF5A623),
            colorBottom: UIColor(rgb: 0xE6862E),
            isEnabled: { LuckgramNearby.isFeatureEnabled },
            make: { luckgramNearbyController(context: $0) }
        )
    ]

    /// Entries whose switch is currently on, updated when a switch (or remote config) changes.
    public static func enabled() -> Signal<[LuckgramDiscoverEntry], NoError> {
        let signals = all.map { entry in
            LuckgramSettings.shared.isEnabledSignal(entry.featureKey) |> map { on -> LuckgramDiscoverEntry? in on ? entry : nil }
        }
        return combineLatest(signals) |> map { $0.compactMap { $0 } }
    }
}
