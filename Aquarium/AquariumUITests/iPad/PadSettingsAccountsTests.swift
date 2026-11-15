//  Settings → Account with more than one account on the iPad: Add Account…
//  (the sheet starts from the server in use; its Cancel), a second account
//  signed in beside the first, the "Signed in" tick on the one in use,
//  switching by a tap, and signing one out of this device by its swipe
//  action and by its press-and-hold menu.
//
//  On an iPhone and an iPad signing an account out of the device asks no
//  question (the confirmation, `settings.accounts.removeConfirm`, is the
//  Mac's): the swipe or the menu does it.
//
//  The second account is suite-spare1. Nothing of either account's is
//  changed on the server; the saved accounts live in the app's test
//  settings, which the next launch starts without.

#if os(iOS)
import XCTest

final class PadSettingsAccountsTests: PadUITestCase {
    private func spare() throws -> QA.Account {
        guard let account = QA.account(named: "suite-spare1") else { throw XCTSkip("no suite-spare1 in suite-accounts.txt") }
        return account
    }

    private func openAccountPage(file: StaticString = #filePath, line: UInt = #line) {
        let page = app.element(TestID.Settings.pageRoot("account"))
        if !page.exists {
            let link = app.button(TestID.Settings.pageLink("account"))
            if !link.exists {
                let gear = app.button(TestID.Sidebar.settings)
                if !gear.exists || !gear.isHittable { revealSidebar() }
                gear.padTap(file: file, line: line)
                app.element(TestID.Settings.root).waitToExist(20, file: file, line: line)
            }
            // The split (landscape) opens on Video; the list alone has links.
            app.element(TestID.Settings.pageLink("account")).padTap(file: file, line: line)
        }
        page.waitToExist(15, file: file, line: line)
    }

    private var accountRows: XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings.accounts.account."))
    }

    private func row(of name: String) -> XCUIElement {
        accountRows.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
    }

    private func key(of row: XCUIElement) -> String {
        String(row.identifier.dropFirst("settings.accounts.account.".count))
    }

    private func signedInAs() -> String { text(app.element(TestID.Settings.accountSignedInAs)) }

    private func field(_ id: String) -> XCUIElement {
        let plain = app.textFields[id]
        return plain.exists ? plain : app.secureTextFields[id]
    }

    /// Add Account… → the sheet, already on this server → the spare's name
    /// and password → signed in as the spare, the sheet gone.
    private func addSpare(_ spare: QA.Account, file: StaticString = #filePath, line: UInt = #line) {
        let add = app.button(TestID.Settings.addAccount)
        XCTAssertTrue(reveal(add), "Add Account…", file: file, line: line)
        add.padTap()
        let sheet = app.element(TestID.Login.root)
        sheet.waitToExist(15, file: file, line: line)
        // "Someone else in the house, on the same server": no address to type.
        app.element(TestID.Login.serverBanner).waitToExist(30, file: file, line: line)
        let user = field(TestID.Login.username)
        user.waitToExist(15, file: file, line: line)
        user.padTap()
        user.typeText(spare.name + "\n")
        let password = field(TestID.Login.password)
        password.waitToExist(10, file: file, line: line)
        if !password.hasFocus { password.padTap() }
        password.typeText(spare.password + "\n")
        XCTAssertTrue(sheet.waitToVanish(60), "the sheet closes once signed in", file: file, line: line)
    }

    func testAddAccountSheetStartsOnThisServerAndCancels() throws {
        launchHome()
        openAccountPage()
        XCTAssertEqual(accountRows.count, 1, "one account to begin with")
        let own = row(of: accountName)
        XCTAssertTrue(own.exists)
        XCTAssertTrue(own.label.contains("Signed in"), "the tick on the account in use: \(own.label)")
        XCTAssertFalse(app.staticTexts["Tap an account to switch to it."].exists, "no switching hint with one account")

        app.button(TestID.Settings.addAccount).padTap()
        let sheet = app.element(TestID.Login.root)
        sheet.waitToExist(15)
        app.element(TestID.Login.serverBanner).waitToExist(30)
        XCTAssertTrue(text(app.element(TestID.Login.serverDetail)).contains("127.0.0.1"), "the server in use, without typing it")
        XCTAssertTrue(field(TestID.Login.username).waitForExistence(timeout: 10))
        attachScreenshot("add account")
        dismissKeyboard()
        let cancel = app.button(TestID.Login.cancel)
        XCTAssertTrue(cancel.exists, "the sheet's Cancel")
        if !cancel.isHittable { sheet.swipeUp() }
        cancel.padTap()
        XCTAssertTrue(sheet.waitToVanish(10), "Cancel closes the sheet")
        XCTAssertEqual(accountRows.count, 1)
        XCTAssertTrue(signedInAs().contains(accountName), "still \(accountName): \(signedInAs())")
    }

    func testSecondAccountSignsInSwitchesBackAndIsSwipedOut() throws {
        let spare = try spare()
        launchHome()
        openAccountPage()
        addSpare(spare)

        // The new account is the one in use.
        openAccountPage()
        XCTAssertTrue(waitUntil(20, "signed in as the spare") { [self] in signedInAs().contains(spare.name) }, "reads \(signedInAs())")
        XCTAssertTrue(waitUntil(10, "two accounts listed") { [self] in accountRows.count == 2 })
        let own = row(of: accountName), other = row(of: spare.name)
        XCTAssertTrue(other.label.contains("Signed in"), "the tick moved to the spare: \(other.label)")
        XCTAssertFalse(own.label.contains("Signed in"), "and left \(accountName): \(own.label)")
        XCTAssertTrue(own.label.contains("127.0.0.1"), "each row names its server: \(own.label)")
        XCTAssertNotEqual(key(of: own), key(of: other))
        XCTAssertTrue(app.staticTexts["Tap an account to switch to it."].exists, "the hint under two accounts")
        attachScreenshot("two accounts")

        // A tap switches.
        own.padTap()
        XCTAssertTrue(waitUntil(30, "back to \(accountName)") { [self] in
            if !app.element(TestID.Settings.pageRoot("account")).exists { openAccountPage() }
            return signedInAs().contains(accountName)
        }, "reads \(signedInAs())")
        XCTAssertTrue(waitUntil(10, "the tick back on \(accountName)") { [self] in row(of: accountName).label.contains("Signed in") })
        XCTAssertFalse(row(of: spare.name).label.contains("Signed in"))

        // The swipe action signs the other out of this device, with no question asked.
        let spareRow = row(of: spare.name)
        XCTAssertTrue(reveal(spareRow))
        let spareKey = key(of: spareRow)
        spareRow.swipeLeft()
        let signOut = app.buttons.matching(identifier: TestID.Settings.accountRemove(spareKey)).firstMatch
        if signOut.waitForExistence(timeout: 5) { signOut.padTap() } else { app.buttons["Sign Out"].padTap() }
        // The toast first: it is up for three seconds.
        expectToast(containing: "Signed \(spare.name) out of this device")
        XCTAssertTrue(spareRow.waitToVanish(15), "the spare's row goes")
        XCTAssertFalse(app.button(TestID.Settings.removeAccountConfirm).exists, "no confirmation on an iPad")
        XCTAssertEqual(accountRows.count, 1)
        XCTAssertTrue(signedInAs().contains(accountName))
    }

    func testAnAccountNotInUseIsSignedOutFromItsMenu() throws {
        let spare = try spare()
        launchHome()
        openAccountPage()
        addSpare(spare)
        openAccountPage()
        XCTAssertTrue(waitUntil(20, "signed in as the spare") { [self] in signedInAs().contains(spare.name) })
        XCTAssertTrue(waitUntil(10, "two accounts listed") { [self] in accountRows.count == 2 })

        // The suite's own account is now the one not in use: its menu signs it out.
        let own = row(of: accountName)
        XCTAssertTrue(reveal(own))
        let ownKey = key(of: own)
        own.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).press(forDuration: 1.2)
        let signOut = menuItem(TestID.Settings.accountRemove(ownKey), label: "Sign Out of This Device")
        signOut.waitToExist(10)
        attachScreenshot("account menu")
        signOut.padTap()
        expectToast(containing: "Signed \(accountName) out of this device")
        XCTAssertTrue(own.waitToVanish(15), "\(accountName)'s row goes")
        XCTAssertEqual(accountRows.count, 1)
        XCTAssertTrue(row(of: spare.name).label.contains("Signed in"))
        XCTAssertTrue(signedInAs().contains(spare.name), "the account in use is untouched: \(signedInAs())")
    }
}
#endif
