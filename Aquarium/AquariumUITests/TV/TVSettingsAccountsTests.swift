//  Two accounts on one Apple TV (Views/TVSettingsView.swift
//  `ServerSettingsPage`, Views/LoginView.swift "Who's watching?"): a press on
//  the other account's row asks Switch or Sign Out of This Apple TV; Switch
//  changes who is signed in; Sign Out takes it off the list; and signing out
//  of the account in use leaves the other one offered on the sign-in screen.
//
//  The second account is suite-spare1, signed in first by a clean launch;
//  the relaunch that keeps its state signs this suite's account in beside it
//  (`TestMode.signIn` replaces the session and keeps the saved account).
//  Nothing of either account's is changed on the server.

#if os(tvOS)
import XCTest

final class TVSettingsAccountsTests: TVSettingsPagesCase {
    private func spare() throws -> QA.Account {
        guard let account = QA.account(named: "suite-spare1") else { throw XCTSkip("no suite-spare1 in suite-accounts.txt") }
        return account
    }

    private var me: String { QA.account()?.name ?? "suite-tv" }

    /// Signed in as the spare, then as this suite's account beside it, in
    /// Settings → Account.
    private func twoAccounts(_ spare: QA.Account, file: StaticString = #filePath, line: UInt = #line) {
        markSessionsStale()
        launch(account: spare)
        app.element(TestID.Home.root).waitToExist(60, file: file, line: line)
        launch(reset: false)
        app.element(TestID.Home.root).waitToExist(60, file: file, line: line)
        assertFocusPresent("Home with two accounts", file: file, line: line)
        enterSettings(file: file, line: line)
        openPage("account", file: file, line: line)
        let signedIn = app.element(TestID.Settings.accountSignedInAs)
        waitUntil("signed in as \(me)", timeout: 20, file: file, line: line) { signedIn.label.contains(self.me) }
    }

    private var accountRows: XCUIElementQuery { app.elements(prefix: "settings.accounts.account.") }

    private func row(of name: String) -> XCUIElement {
        accountRows.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
    }

    private func key(of row: XCUIElement) -> String {
        String(row.identifier.dropFirst("settings.accounts.account.".count))
    }

    func testAnotherAccountsRowOffersSwitchAndSignOutAndMenuKeepsBoth() throws {
        let spare = try spare()
        twoAccounts(spare)
        waitUntil("both accounts listed", timeout: 15) { [weak self] in (self?.accountRows.count ?? 0) == 2 }
        let other = row(of: spare.name)
        XCTAssertTrue(other.exists, "\(spare.name) isn't on the list")
        let key = key(of: other)
        choose(other.identifier)
        let cancel = app.element(TestID.TVSettings.accountActionsCancel)
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "a press on another account asked nothing")
        XCTAssertTrue(app.element(TestID.Settings.accountSwitch(key)).exists, "no Switch in the dialog")
        XCTAssertTrue(app.element(TestID.Settings.accountRemove(key)).exists, "no Sign Out of This Apple TV in the dialog")
        attachScreenshot("account dialog")
        Remote.menu()
        XCTAssertTrue(cancel.waitToVanish(10), "Menu left the dialog up")
        XCTAssertEqual(accountRows.count, 2, "Menu changed the list")
        XCTAssertTrue(app.element(TestID.Settings.accountSignedInAs).label.contains(me), "Menu switched accounts")
        assertFocusPresent("Account after the dialog")
    }

    func testSwitchingToTheOtherAccountSignsItIn() throws {
        let spare = try spare()
        twoAccounts(spare)
        let other = row(of: spare.name)
        XCTAssertTrue(other.waitForExistence(timeout: 15), "\(spare.name) isn't on the list")
        let key = key(of: other)
        choose(other.identifier)
        app.element(TestID.Settings.accountSwitch(key)).waitToExist(10)
        XCTAssertTrue(focusDialogButton("Switch to"), "can't reach Switch in the dialog (on \(focusedLabel))")
        Remote.select()
        let toast = app.element(TestID.Shell.toastText)
        waitUntil("the switch to be announced", timeout: 30) { toast.exists && toast.label.contains("Switched to \(spare.name)") }
        // The shell is rebuilt for the new session; back to Account to see who.
        if !app.element(TestID.Settings.pageRoot("account")).waitForExistence(timeout: 5) {
            if !app.element(TestID.Settings.root).exists { enterSettings() }
            openPage("account")
        }
        let signedIn = app.element(TestID.Settings.accountSignedInAs)
        waitUntil("signed in as \(spare.name)", timeout: 20) { signedIn.label.contains(spare.name) }
        assertFocusPresent("after switching accounts")
    }

    func testSigningTheOtherAccountOutOfThisAppleTVTakesItOffTheList() throws {
        let spare = try spare()
        twoAccounts(spare)
        let other = row(of: spare.name)
        XCTAssertTrue(other.waitForExistence(timeout: 15), "\(spare.name) isn't on the list")
        let key = key(of: other)
        choose(other.identifier)
        app.element(TestID.Settings.accountRemove(key)).waitToExist(10)
        XCTAssertTrue(focusDialogButton("Sign Out of This"), "can't reach Sign Out in the dialog (on \(focusedLabel))")
        Remote.select()
        XCTAssertTrue(other.waitToVanish(20), "\(spare.name) stayed on the list")
        XCTAssertEqual(accountRows.count, 1)
        XCTAssertTrue(app.element(TestID.Settings.accountSignedInAs).label.contains(me), "the account in use changed")
        let toast = app.element(TestID.Shell.toastText)
        if toast.exists { XCTAssertTrue(toast.label.contains(spare.name), toast.label) }
        assertFocusPresent("Account after signing the other account out")
    }

    func testSigningOutLeavesTheOtherAccountOnWhosWatching() throws {
        // `LoginView.savedAccounts`: the accounts still on this Apple TV are a
        // press away, with no password.
        let spare = try spare()
        twoAccounts(spare)
        choose(TestID.Settings.signOut)
        app.element(TestID.Settings.signOutConfirm).waitToExist(10)
        XCTAssertTrue(focusDialogButton("Sign out"), "can't reach Sign out in the dialog (on \(focusedLabel))")
        Remote.select()
        app.element(TestID.Shell.signedOut).waitToExist(30)
        let offered = app.elements(prefix: "login.accounts.account.").matching(NSPredicate(format: "label CONTAINS %@", spare.name)).firstMatch
        XCTAssertTrue(offered.waitForExistence(timeout: 20), "\(spare.name) isn't offered on Who's watching?")
        XCTAssertFalse(app.elements(prefix: "login.accounts.account.").matching(NSPredicate(format: "label CONTAINS %@", me)).firstMatch.exists,
                       "the account just signed out is still offered")
        attachScreenshot("who's watching")
        XCTAssertTrue(focusInColumn(offered) || Remote.focus(on: offered, in: app),
                      "can't reach \(spare.name) (on \(focused?.summary ?? "nothing"))")
        Remote.select()
        app.element(TestID.Home.root).waitToExist(60)
        assertFocusPresent("Home as \(spare.name)")
        enterSettings()
        openPage("account")
        XCTAssertTrue(app.element(TestID.Settings.accountSignedInAs).label.contains(spare.name),
                      app.element(TestID.Settings.accountSignedInAs).label)
    }
}
#endif
