import Foundation
import UIKit
import Display
import SwiftSignalKit
import AccountContext
import LuckgramDiscover

/// "Discover" entry area at the top of Contacts (25 People Nearby, 26 Square, ...). Each entry is
/// shown while its remote-aware switch is on. To add one, append to `all` — ContactListUI only
/// renders this list.
public struct LuckgramDiscoverEntry {
    public let featureKey: String
    public let title: () -> String
    /// Bundle image name used for the row icon.
    public let iconName: String
    public let isEnabled: () -> Bool
    public let make: (AccountContext) -> ViewController
}

public enum LuckgramDiscoverEntries {
    public static let all: [LuckgramDiscoverEntry] = [
        LuckgramDiscoverEntry(
            featureKey: NearbyLogic.featureKey,
            title: { NearbyLogic.Texts(zh: LuckgramStrings.isChinese).title },
            iconName: "Chat/Attach Menu/Location",
            isEnabled: { LuckgramNearby.isFeatureEnabled },
            make: { luckgramNearbyController(context: $0) }
        ),
        LuckgramDiscoverEntry(
            featureKey: SquareLogic.featureKey,
            title: { LuckgramSquare.texts.title },
            iconName: "Chat/Context Menu/Channels",
            isEnabled: { LuckgramSquare.isFeatureEnabled },
            make: { luckgramSquareController(context: $0) }
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
