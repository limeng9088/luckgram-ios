import Foundation
import XCTest
import Postbox
import TelegramCore
@testable import NotificationServiceExtensionLib

/// With more than one account signed in, a notification names the account it was delivered to
/// in front of the title ("[peter] Alice", Luckgram spec 09; same as Android).
final class NotificationRecipientAccountTests: XCTestCase {
    private func record(_ id: Int64, loggedOut: Bool = false) -> AccountRecord<TelegramAccountManagerTypes.Attribute> {
        return AccountRecord<TelegramAccountManagerTypes.Attribute>(id: AccountRecordId(rawValue: id), attributes: loggedOut ? [.loggedOut(LoggedOutAccountAttribute())] : [], temporarySessionId: nil)
    }

    private func user(firstName: String?, username: String?, phone: String? = nil) -> TelegramUser {
        return TelegramUser(
            id: PeerId(namespace: Namespaces.Peer.CloudUser, id: PeerId.Id._internalFromInt64Value(1001)),
            accessHash: nil,
            firstName: firstName,
            lastName: nil,
            username: username,
            phone: phone,
            photo: [],
            botInfo: nil,
            restrictionInfo: nil,
            flags: [],
            emojiStatus: nil,
            usernames: [],
            storiesHidden: nil,
            nameColor: nil,
            backgroundEmojiId: nil,
            profileColor: nil,
            profileBackgroundEmojiId: nil,
            subscriberCount: nil,
            verificationIconFileId: nil
        )
    }

    // MARK: - When, and which name

    func testASingleAccountIsNotNamed() {
        XCTAssertFalse(notificationsNameRecipientAccount(records: [self.record(1)]))
    }

    func testSeveralAccountsAreNamed() {
        XCTAssertTrue(notificationsNameRecipientAccount(records: [self.record(1), self.record(2)]))
    }

    /// A logged-out record lingers until its cleanup finishes, but it is no longer an account the
    /// user has to tell apart.
    func testALoggedOutRecordDoesNotCountAsAnotherAccount() {
        XCTAssertFalse(notificationsNameRecipientAccount(records: [self.record(1), self.record(2, loggedOut: true)]))
    }

    func testTheFirstNameNamesTheAccount() {
        XCTAssertEqual(notificationRecipientAccountName(accountPeer: .user(self.user(firstName: "Peter", username: "peter"))), "Peter")
    }

    func testTheLocalNameWins() {
        XCTAssertEqual(notificationRecipientAccountName(accountPeer: .user(self.user(firstName: "Peter", username: "peter")), alias: "Work"), "Work")
    }

    func testAnEmptyLocalNameFallsBackToTheFirstName() {
        XCTAssertEqual(notificationRecipientAccountName(accountPeer: .user(self.user(firstName: "Peter", username: nil)), alias: ""), "Peter")
    }

    func testAnAccountWithoutAUsernameIsNamedByItsName() {
        XCTAssertEqual(notificationRecipientAccountName(accountPeer: .user(self.user(firstName: "Peter", username: nil))), "Peter")
    }

    func testAnAccountWhosePeerIsUnknownIsNotNamed() {
        XCTAssertNil(notificationRecipientAccountName(accountPeer: nil))
    }

    func testAnAccountWithNoNameAtAllIsNotNamed() {
        XCTAssertNil(notificationRecipientAccountName(accountPeer: .user(self.user(firstName: nil, username: nil))))
    }

    // MARK: - Where the name goes

    func testTheTitleNamesTheRecipientAccount() {
        let names = NotificationNames(title: "Alice", senderName: nil, silent: false, recipientAccountName: "peter")

        XCTAssertEqual(names.title, "[peter] Alice")
    }

    func testWithOneAccountTheTitleIsUnchanged() {
        let names = NotificationNames(title: "Alice", senderName: "Alice", silent: false, recipientAccountName: nil)

        XCTAssertEqual(names.title, "Alice")
        XCTAssertEqual(names.displayedSenderName, "Alice")
        XCTAssertEqual(names.donatedSenderName, "Alice")
    }

    /// The muted marker describes the message, so it stays at the very end.
    func testTheMutedMarkerStaysLast() {
        let names = NotificationNames(title: "Alice", senderName: "Alice", silent: true, recipientAccountName: "peter")

        XCTAssertEqual(names.title, "[peter] Alice 🔕")
        XCTAssertEqual(names.displayedSenderName, "[peter] Alice 🔕")
    }

    /// On a communication notification the system draws the sender's name in place of the title,
    /// so the account has to be in it too. The copy handed to the system for Siri, share sheet and
    /// Focus suggestions is the sender alone: the account is not part of who they are.
    func testOnlyTheDisplayedSenderNamesTheRecipientAccount() {
        let names = NotificationNames(title: "Alice", senderName: "Alice", silent: false, recipientAccountName: "peter")

        XCTAssertEqual(names.displayedSenderName, "[peter] Alice")
        XCTAssertEqual(names.donatedSenderName, "Alice")
    }

    func testTheDonatedSenderKeepsTheMutedMarker() {
        let names = NotificationNames(title: "Alice", senderName: "Alice", silent: true, recipientAccountName: "peter")

        XCTAssertEqual(names.donatedSenderName, "Alice 🔕")
    }

    /// No title means the chat's message previews are off. The account is then left out of both
    /// the title and the sender's name the system draws, as it was before 2021.
    func testANotificationWithoutATitleDoesNotNameTheAccount() {
        for title in [nil, ""] as [String?] {
            let names = NotificationNames(title: title, senderName: "Alice", silent: false, recipientAccountName: "peter")

            XCTAssertEqual(names.title, title)
            XCTAssertEqual(names.displayedSenderName, "Alice")
        }
    }

    func testANotificationWithoutSenderInfoHasNoSenderNames() {
        let names = NotificationNames(title: "Alice", senderName: nil, silent: false, recipientAccountName: "peter")

        XCTAssertNil(names.displayedSenderName)
        XCTAssertNil(names.donatedSenderName)
    }

    func testARightToLeftTitleGetsTheSamePrefix() {
        let names = NotificationNames(title: "علي", senderName: "علي", silent: false, recipientAccountName: "peter")

        XCTAssertEqual(names.title, "[peter] علي")
        XCTAssertEqual(names.displayedSenderName, "[peter] علي")
    }

    /// Topic notifications already carry "Topic (Forum)" in both the title and the sender's name;
    /// the account goes in front of it.
    func testATopicTitleKeepsTheAccountAfterIt() {
        let names = NotificationNames(title: "Releases (Dev Forum)", senderName: "Releases (Dev Forum)", silent: false, recipientAccountName: "peter")

        XCTAssertEqual(names.title, "[peter] Releases (Dev Forum)")
        XCTAssertEqual(names.displayedSenderName, "[peter] Releases (Dev Forum)")
    }
}
