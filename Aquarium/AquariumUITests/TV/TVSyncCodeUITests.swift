//  The audio sync clip and its code (Player/TV/SyncCodeOverlay.swift), driven
//  the way a viewer reaches it: Settings → Audio → a frame rate's row → the
//  flashing-images warning → Play. The QR code in the corner is read back
//  off a screenshot, the way the iPhone's Measure screen reads it off the TV.

#if os(tvOS)
import XCTest
import CoreImage
import UIKit

final class TVSyncCodeUITests: TVPlayerTestCase {
    /// The text in the QR code on screen, if one can be read.
    private func readCode() -> String? {
        guard let cg = app.screenshot().image.cgImage else { return nil }
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        return detector?.features(in: CIImage(cgImage: cg)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
    }

    private func startClip(fps: Int, file: StaticString = #filePath, line: UInt = #line) {
        launchHome(file: file, line: line)
        openTab("settings", title: "Settings", anchor: TestID.Settings.root, file: file, line: line)
        Remote.press(.down)
        XCTAssertTrue(focusInColumn(app.element(TestID.Settings.pageLink("audio"))), file: file, line: line)
        Remote.select()
        app.element(TestID.Settings.pageRoot("audio")).waitToExist(15, file: file, line: line)
        XCTAssertTrue(focusInColumn(app.element(TestID.TVSettings.audioDelay(fps))), file: file, line: line)
        Remote.select()
        let play = app.element(TestID.TVSettings.syncTestPlay)
        play.waitToExist(10, file: file, line: line)
        XCTAssertTrue(focusInColumn(play) || Remote.focus(on: play, in: app), file: file, line: line)
        Remote.select()
        app.element(TestID.Player.root).waitToExist(30, file: file, line: line)
        app.element(TestID.Player.syncCodeImage).waitToExist(30, file: file, line: line)
    }

    func testTheClipCarriesAReadableCodeForItsRate() {
        startClip(fps: 24)
        var code: String?
        waitUntil("a readable code", timeout: 20) { [weak self] in
            code = self?.readCode()
            return code != nil
        }
        attachScreenshot("24 fps clip")
        XCTAssertNotNil(code)
        XCTAssertTrue(code?.hasPrefix("AQSYNC:1:24:") == true, "code reads \(code ?? "nothing")")
    }

    func testEachPresetRateHasItsOwnClip() {
        startClip(fps: 60)
        var code: String?
        waitUntil("a readable code", timeout: 20) { [weak self] in
            code = self?.readCode()
            return code != nil
        }
        XCTAssertTrue(code?.hasPrefix("AQSYNC:1:60:") == true, "code reads \(code ?? "nothing")")
    }

    func testSwipeDownOpensSyncAndAStepRedrawsTheCode() {
        // bffc9e7: the panel opens straight on Sync over the clip. The code is
        // redrawn as the delay moves, so the phone reads what is in force.
        startClip(fps: 24)
        var before: String?
        waitUntil("a readable code", timeout: 20) { [weak self] in
            before = self?.readCode()
            return before != nil
        }
        TVHook.remote("swipeDown")
        app.element(TestID.Player.panel).waitToExist(10)
        let syncTab = app.element(TestID.Player.panelTab("sync"))
        syncTab.waitToExist(10)
        waitUntil("the Sync tab focused", timeout: 10) { syncTab.hasFocusInside }
        let value = app.element(TestID.Player.syncValue)
        value.waitToExist(10)
        pick(TestID.Player.syncStep(50))
        waitUntil("the reading to move", timeout: 10) { value.label != "In step" && !value.label.isEmpty }
        // Away with the panel so the corner is clear, then read again.
        Remote.menu()
        Remote.menu()
        var after: String?
        waitUntil("the code to change", timeout: 20) { [weak self] in
            after = self?.readCode()
            return after != nil && after != before
        }
        XCTAssertNotEqual(after, before)
        let delay = after.flatMap { Int($0.split(separator: ":").last ?? "") }
        XCTAssertNotNil(delay)
        XCTAssertEqual(abs(delay ?? 0), 50, "one +50 step from in step, in the stored sign: \(after ?? "")")
        // In step again for the next run.
        TVHook.remote("swipeDown")
        if app.element(TestID.Player.panel).waitForExistence(timeout: 10) { pick(TestID.Player.syncReset) }
    }

    func testMenuLeavesTheClipBackToSettings() {
        startClip(fps: 25)
        Remote.menu()
        if app.element(TestID.Player.root).exists { Remote.menu() }
        XCTAssertTrue(app.element(TestID.Player.root).waitToVanish(15), "the clip didn't close")
        app.element(TestID.Settings.pageRoot("audio")).waitToExist(10)
        assertFocusPresent("Settings → Audio after the clip")
    }
}
#endif
