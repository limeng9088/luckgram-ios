import Foundation
import SwiftSignalKit
import TelegramCore
import TelegramUIPreferences
import AccountContext
import LuckgramAccountsStore

// Luckgram 09 (more accounts): 20 accounts for everyone, no Premium tier.
public let maximumNumberOfAccounts = LuckgramAccountsStore.maxAccounts
public let maximumPremiumNumberOfAccounts = LuckgramAccountsStore.maxAccounts

/// Luckgram 09: the account as shown in account lists, with its local name in front ("Work (Noah)").
private func luckgramDisplayPeer(_ peer: EnginePeer, accountId: AccountRecordId) -> EnginePeer {
    guard case let .user(user) = peer, LuckgramAccountsStore.shared.alias(accountId.int64) != nil else {
        return peer
    }
    let name = [user.firstName, user.lastName].compactMap({ $0 }).filter({ !$0.isEmpty }).joined(separator: " ")
    return .user(user.withUpdatedNames(firstName: LuckgramAccountsStore.shared.displayName(accountId.int64, name: name), lastName: nil))
}

public func activeAccountsAndPeers(context: AccountContext, includePrimary: Bool = false) -> Signal<((AccountContext, EnginePeer)?, [(AccountContext, EnginePeer, Int32)]), NoError> {
    let sharedContext = context.sharedContext
    return context.sharedContext.activeAccountContexts
    |> mapToSignal { primary, activeAccounts, _ -> Signal<((AccountContext, EnginePeer)?, [(AccountContext, EnginePeer, Int32)]), NoError> in
        var accounts: [Signal<(AccountContext, EnginePeer, Int32)?, NoError>] = []
        func accountWithPeer(_ context: AccountContext) -> Signal<(AccountContext, EnginePeer, Int32)?, NoError> {
            return combineLatest(context.account.postbox.peerView(id: context.account.peerId), renderedTotalUnreadCount(accountManager: sharedContext.accountManager, engine: context.engine))
            |> map { view, totalUnreadCount -> (EnginePeer?, Int32) in
                return (view.peers[view.peerId].flatMap(EnginePeer.init), totalUnreadCount.0)
            }
            |> distinctUntilChanged { lhs, rhs in
                if lhs.0 != rhs.0 {
                    return false
                }
                if lhs.1 != rhs.1 {
                    return false
                }
                return true
            }
            |> map { peer, totalUnreadCount -> (AccountContext, EnginePeer, Int32)? in
                if let peer = peer {
                    return (context, peer, totalUnreadCount)
                } else {
                    return nil
                }
            }
        }
        for (_, context, _) in activeAccounts {
            accounts.append(accountWithPeer(context))
        }
        
        // Luckgram 09: the user's account order and local names; re-emit when they change.
        return combineLatest(combineLatest(accounts), LuckgramAccountsStore.shared.updated)
        |> map { accounts, _ -> ((AccountContext, EnginePeer)?, [(AccountContext, EnginePeer, Int32)]) in
            var primaryRecord: (AccountContext, EnginePeer)?
            if let first = accounts.filter({ $0?.0.account.id == primary?.account.id }).first, let (account, peer, _) = first {
                primaryRecord = (account, peer)
            }
            let accounts: [(AccountContext, EnginePeer, Int32)?] = LuckgramAccountsStore.shared.sorted(accounts.compactMap({ $0 }), id: { $0.0.account.id.int64 }).map { item -> (AccountContext, EnginePeer, Int32)? in
                return (item.0, luckgramDisplayPeer(item.1, accountId: item.0.account.id), item.2)
            }
            let accountRecords: [(AccountContext, EnginePeer, Int32)] = (includePrimary ? accounts : accounts.filter({ $0?.0.account.id != primary?.account.id })).compactMap({ $0 })
            return (primaryRecord, accountRecords)
        }
    }
}
