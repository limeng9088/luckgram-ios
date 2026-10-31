import Foundation
import TelegramCore
import LuckgramAccountsStore

/// Whether a notification has to say which account it was delivered to: more than one is signed
/// in (bugs.telegram.org/c/18387). Every record not marked logged out counts. The app also leaves
/// out a record whose session turns out to be unauthorized when it opens it, which the extension
/// cannot know without opening every account; such a record counts here until it is marked.
func notificationsNameRecipientAccount(records: [AccountRecord<TelegramAccountManagerTypes.Attribute>]) -> Bool {
    let accountCount = records.filter { record in
        return !record.attributes.contains(where: { attribute in
            if case .loggedOut = attribute {
                return true
            } else {
                return false
            }
        })
    }.count
    return accountCount > 1
}

/// The name a notification uses for the account it was delivered to (Luckgram 09, same as
/// Android): the local name set in Settings → Manage accounts, else the account's first name.
func notificationRecipientAccountName(accountPeer: EnginePeer?, alias: String? = nil) -> String? {
    if let alias, !alias.isEmpty {
        return alias
    }
    guard let accountPeer else {
        return nil
    }
    if case let .user(user) = accountPeer, let firstName = user.firstName, !firstName.isEmpty {
        return firstName
    }
    let title = accountPeer.debugDisplayTitle
    return title.isEmpty ? nil : title
}

/// The names one notification is drawn and donated with.
///
/// On iOS 15+ a notification with sender info is a communication notification, and the system
/// draws the sender's name in place of `title` (it also hides `subtitle`, so the account cannot
/// go there). The account therefore goes into both `title` and `displayedSenderName`. The
/// interaction donated for Siri, share sheet and Focus suggestions keeps the sender alone:
/// the system draws the notification from the intent it is updated from, not the donated one.
struct NotificationNames: Equatable {
    var title: String?
    /// The sender's name the notification is drawn with.
    var displayedSenderName: String?
    /// The sender's name handed to the system with the donated interaction.
    var donatedSenderName: String?

    init(title: String?, senderName: String?, silent: Bool, recipientAccountName: String?) {
        // No title means the chat's message previews are off, and then the account is left out,
        // as it was before 2021, even where the system still draws the sender's name.
        let recipientAccountName = (title?.isEmpty ?? true) ? nil : recipientAccountName

        func decorated(_ name: String, recipientAccountName: String?) -> String {
            // Luckgram 09: the account goes in front, "[Work] Noah" (spec 09, same as Android).
            var result = LuckgramAccountsStore.notificationTitle(name, accountName: recipientAccountName)
            // The muted marker describes the message, so it stays last.
            if silent {
                result += " 🔕"
            }
            return result
        }

        self.title = title.flatMap { decorated($0, recipientAccountName: recipientAccountName) }
        self.displayedSenderName = senderName.flatMap { decorated($0, recipientAccountName: recipientAccountName) }
        self.donatedSenderName = senderName.flatMap { decorated($0, recipientAccountName: nil) }
    }
}
