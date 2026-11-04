import Foundation
import UIKit
import TelegramPresentationData

public extension LuckgramTranslateOut {
    /// specs#105: the language list for reading translation, with its recently used languages on top.
    /// Same list as `makeLanguagePicker`; kept in its own file so translate-out (#104) can change that one freely.
    static func makeReadingLanguagePicker(strings: PresentationStrings?, isDark: Bool, selected: String?, recent: [String], completion: @escaping (String) -> Void) -> UIViewController {
        let picker = LuckgramTranslateOutLanguagePicker(strings: LuckgramTranslateOut.Strings(strings), selected: selected, recent: recent, isDark: isDark, completion: completion)
        return picker.wrappedInNavigation()
    }
}
