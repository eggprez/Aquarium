//  Where the access token lives.
//
//  The Linux build puts it in the Secret Service keyring and falls back to the
//  config file when no keyring is running. Apple platforms always have a
//  keychain, so there is no fallback here and no "stored in the config file"
//  state for Settings to warn about. Requests carry it in a header; the one
//  exception is a stream download, whose segment requests AVFoundation makes
//  itself and which can only take it in the URL (`JellyfinClient.authorized`).

import Foundation
import Security

enum Keychain {
    /// The app's name before it became Aquarium. Renaming it would orphan every
    /// saved token and sign everyone out, so it stays.
    private static let service = "FellyJin"

    /// One entry per (server, user): signing in to a second server does not
    /// evict the first, which is what makes switching back cheap.
    private static func account(server: String, userId: String) -> String {
        "\(server)|\(userId)"
    }

    /// Whether this device takes part in iCloud sync — the same switch
    /// `Preferences.syncsAcrossDevices` keeps, read straight from the defaults
    /// because this is called from off the main actor too. On unless turned
    /// off.
    private static var syncs: Bool {
        let d = UserDefaults.standard
        return d.object(forKey: "cloud_sync") == nil ? true : d.bool(forKey: "cloud_sync")
    }

    private static func baseQuery(_ acct: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: acct,
        ]
    }

    /// False when the keychain refused the write — a sign-in that reports
    /// success without a stored token is signed out again at the next launch,
    /// so the caller says so instead.
    @discardableResult
    static func store(token: String, server: String, userId: String) -> Bool {
        let acct = account(server: server, userId: userId)
        var query = baseQuery(acct)
        let synchronised = syncs
        // Syncing, this matches both the synchronised copy and any device-only
        // one an earlier build wrote, so storing a token replaces rather than
        // shadows. Opted out, only this device's own copy is replaced: the
        // synchronised one may be what another device is signed in with.
        var wipe = query
        wipe[kSecAttrSynchronizable as String] = synchronised ? kSecAttrSynchronizableAny as Any : kCFBooleanFalse as Any
        SecItemDelete(wipe as CFDictionary)
        query[kSecValueData as String] = Data(token.utf8)
        // Carried by iCloud Keychain, so a second Apple TV signed in to the
        // same iCloud account finds the token already there and never shows the
        // sign-in screen. See `CloudSync`, which sends the rest of the account
        // — everything except this and the device id. Not when this device
        // has opted out of sync.
        query[kSecAttrSynchronizable as String] = (synchronised ? kCFBooleanTrue : kCFBooleanFalse) as Any
        // The token is only ever needed while the app is in use, but background
        // downloads and progress sync run with the screen locked, so it has to
        // survive that — "after first unlock" is the weakest class that does.
        // A copy that is not synchronised stays on this device as well: left
        // at the plain class it would still travel in an encrypted backup and
        // be restored onto whatever device that backup lands on. (The
        // synchronised copy cannot take the device-only class.)
        query[kSecAttrAccessible as String] = synchronised
            ? kSecAttrAccessibleAfterFirstUnlock
            : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var status = SecItemAdd(query as CFDictionary, nil)
        // A build signed without iCloud Keychain (ad-hoc, or no provisioning
        // profile) is refused a synchronised item outright. Better a token that
        // stays on this device than a sign-in that fails after the server has
        // already said yes.
        if status == errSecMissingEntitlement, synchronised {
            query[kSecAttrSynchronizable as String] = kCFBooleanFalse as Any
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(query as CFDictionary, nil)
        }
        #if os(tvOS)
        Household.store(Data(token.utf8), acct)
        #endif
        return status == errSecSuccess
    }

    static func token(server: String, userId: String) -> String? {
        let acct = account(server: server, userId: userId)
        // This device's own copy first — the one it writes when opted out of
        // sync — then the synchronised one.
        if let own = token(acct, synchronizable: kCFBooleanFalse as Any)
            ?? token(acct, synchronizable: kCFBooleanTrue as Any) { return own }
        #if os(tvOS)
        // Signed in under another of this Apple TV's users.
        if let data = Household.read(acct), let shared = String(data: data, encoding: .utf8), !shared.isEmpty {
            return shared
        }
        #endif
        return nil
    }

    private static func token(_ acct: String, synchronizable: Any) -> String? {
        var query = baseQuery(acct)
        query[kSecAttrSynchronizable as String] = synchronizable
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let s = String(data: data, encoding: .utf8), !s.isEmpty
        else { return nil }
        return s
    }

    /// Put the token where the sync switch now says it belongs, without
    /// losing it. Called when the switch changes.
    ///
    /// Turned on, it becomes the synchronised copy (and the device-only one
    /// goes). Turned off, this device gets a copy of its own and the
    /// synchronised one is left where it is — other devices may be signed in
    /// with it, and opting this one out is not signing them out.
    static func relocate(server: String, userId: String) {
        guard let current = token(server: server, userId: userId) else { return }
        store(token: current, server: server, userId: userId)
    }

    /// Signing out removes both copies — and removing the synchronised one
    /// signs the account out of every device sharing this iCloud Keychain,
    /// which is what "sign out" is expected to mean once the sign-in itself is
    /// shared. A device opted out of sync removes only its own copy.
    static func delete(server: String, userId: String) {
        var query = baseQuery(account(server: server, userId: userId))
        query[kSecAttrSynchronizable as String] = syncs ? kSecAttrSynchronizableAny as Any : kCFBooleanFalse as Any
        SecItemDelete(query as CFDictionary)
        #if os(tvOS)
        Household.delete(account(server: server, userId: userId))
        #endif
    }

    #if os(tvOS)
    /// Copy this user's token to where the Apple TV's other users can read
    /// it, if it isn't there already.
    static func shareToken(server: String, userId: String) {
        let acct = account(server: server, userId: userId)
        guard Household.read(acct) == nil,
              let own = token(acct, synchronizable: kCFBooleanFalse as Any) ?? token(acct, synchronizable: kCFBooleanTrue as Any)
        else { return }
        Household.store(Data(own.utf8), acct)
    }

    // MARK: - The Apple TV's other users

    /// What every user of this Apple TV can see.
    ///
    /// With `runs-as-current-user` each Apple TV user gets a keychain, a
    /// container and defaults of their own, so a second person's first launch
    /// is a sign-in screen that knows nothing — not the server, not who else
    /// lives here. The `-with-user-independent-keychain` form of the
    /// entitlement adds one keychain they all share, reached by putting
    /// `kSecUseUserIndependentKeychain` in the query. A copy of each token goes
    /// in it, and the list of accounts they belong to, which is what lets the
    /// sign-in screen offer "who's watching?" to someone it has never met.
    ///
    /// Every call here may fail — a build signed without the entitlement, a
    /// Simulator — and every failure means only that there is no household:
    /// the per-user keychain above is still the one that counts.
    enum Household {
        private static let listAccount = "household-accounts"

        private static func query(_ acct: String) -> [String: Any] {
            var query = baseQuery(acct)
            query[kSecUseUserIndependentKeychain as String] = kCFBooleanTrue as Any
            query[kSecAttrSynchronizable as String] = kCFBooleanFalse as Any
            return query
        }

        static func store(_ data: Data, _ acct: String) {
            var item = query(acct)
            SecItemDelete(item as CFDictionary)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(item as CFDictionary, nil)
        }

        static func read(_ acct: String) -> Data? {
            var item = query(acct)
            item[kSecReturnData as String] = true
            item[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            guard SecItemCopyMatching(item as CFDictionary, &out) == errSecSuccess else { return nil }
            return out as? Data
        }

        static func delete(_ acct: String) {
            SecItemDelete(query(acct) as CFDictionary)
        }

        /// Everyone signed in on this Apple TV, under whichever of its users.
        static var accounts: [SavedSession] {
            get {
                read(listAccount).flatMap { try? JSONDecoder().decode([SavedSession].self, from: $0) } ?? []
            }
            set {
                if let data = try? JSONEncoder().encode(newValue) { store(data, listAccount) }
            }
        }
    }
    #endif
}
