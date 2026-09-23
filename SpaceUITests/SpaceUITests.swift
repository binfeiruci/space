import AppKit
import Carbon
import XCTest

final class SpaceUITests: XCTestCase {
    private var previousInputSource: TISInputSource?
    private var isolatedApp: XCUIApplication?
    private var isolatedDefaultsSuiteName: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        previousInputSource = TISCopyCurrentKeyboardInputSource()
            .takeRetainedValue()
        let english = TISCopyCurrentASCIICapableKeyboardInputSource()
            .takeRetainedValue()
        XCTAssertEqual(TISSelectInputSource(english), noErr)
    }

    override func tearDownWithError() throws {
        if let isolatedApp, isolatedApp.state != .notRunning {
            isolatedApp.terminate()
        }
        isolatedApp = nil

        if let isolatedDefaultsSuiteName {
            removeDefaultsSuite(named: isolatedDefaultsSuiteName)
            self.isolatedDefaultsSuiteName = nil
        }

        if let previousInputSource {
            XCTAssertEqual(TISSelectInputSource(previousInputSource), noErr)
            self.previousInputSource = nil
        }
        try super.tearDownWithError()
    }

    private func removeDefaultsSuite(named name: String) {
        autoreleasepool {
            let defaults = UserDefaults(suiteName: name)
            defaults?.removePersistentDomain(forName: name)
            defaults?.synchronize()
        }

        let preferencesURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences", isDirectory: true)
        try? FileManager.default.removeItem(
            at: preferencesURL.appendingPathComponent("\(name).plist")
        )
    }

    @MainActor
    func testNewTabCreatesAnotherTab() throws {
        let app = launchIsolatedApp()

        let rows = terminalTabRows(in: app)
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 3))
        app.typeKey("t", modifierFlags: .command)

        expectation(
            for: NSPredicate { _, _ in rows.count == 2 },
            evaluatedWith: nil
        )
        waitForExpectations(timeout: 3)
    }

    @MainActor
    func testNewTabBelowCreatesAnotherTab() throws {
        let app = launchIsolatedApp()

        let rows = terminalTabRows(in: app)
        let firstRow = rows.firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 3))
        firstRow.rightClick()
        let newTabBelowMenuItem = app.menuItems["New Tab Below"]
        XCTAssertTrue(newTabBelowMenuItem.waitForExistence(timeout: 3))
        newTabBelowMenuItem.click()

        expectation(
            for: NSPredicate { _, _ in rows.count == 2 },
            evaluatedWith: nil
        )
        waitForExpectations(timeout: 3)
    }

    @MainActor
    func testDuplicateTabCreatesAnotherTab() throws {
        let app = launchIsolatedApp()

        let rows = terminalTabRows(in: app)
        let firstRow = rows.firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 3))
        firstRow.rightClick()
        let duplicateTabMenuItem = app.menuItems["Duplicate Tab"]
        XCTAssertTrue(duplicateTabMenuItem.waitForExistence(timeout: 3))
        duplicateTabMenuItem.click()

        expectation(
            for: NSPredicate { _, _ in rows.count == 2 },
            evaluatedWith: nil
        )
        waitForExpectations(timeout: 3)
    }

    @MainActor
    func testTabDividerCanBeAddedAndRemoved() throws {
        let app = launchIsolatedApp()

        let rows = terminalTabRows(in: app)
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 3))
        app.typeKey("t", modifierFlags: .command)
        expectation(
            for: NSPredicate { _, _ in rows.count == 2 },
            evaluatedWith: nil
        )
        waitForExpectations(timeout: 3)

        let dividers = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "terminal-tab-divider:"
            )
        )
        rows.firstMatch.rightClick()
        let newDividerMenuItem = app.menuItems["New Divider Below"]
        XCTAssertTrue(newDividerMenuItem.waitForExistence(timeout: 3))
        newDividerMenuItem.click()
        let divider = dividers.firstMatch
        XCTAssertTrue(divider.waitForExistence(timeout: 3))

        rows.firstMatch.rightClick()
        XCTAssertTrue(newDividerMenuItem.waitForExistence(timeout: 3))
        XCTAssertTrue(newDividerMenuItem.isEnabled)
        app.typeKey(.escape, modifierFlags: [])

        divider.rightClick()
        let removeDivider = app.menuItems["Remove Divider"]
        XCTAssertTrue(removeDivider.waitForExistence(timeout: 3))
        removeDivider.click()
        XCTAssertEqual(dividers.count, 0)
    }

    @MainActor
    func testNewSplitsCreateExpectedPanes() throws {
        let app = launchIsolatedApp()

        let panes = app.descendants(matching: .any).matching(
            identifier: "terminal-split-pane"
        )
        let dividers = app.descendants(matching: .any).matching(
            identifier: "terminal-split-divider"
        )
        XCTAssertEqual(panes.count, 1)
        app.typeKey("d", modifierFlags: .command)
        app.typeKey("d", modifierFlags: [.command, .shift])

        expectation(
            for: NSPredicate { _, _ in
                panes.count == 3 && dividers.count == 2
            },
            evaluatedWith: nil
        )
        waitForExpectations(timeout: 3)
    }

    @MainActor
    func testClosingThirdSplitKeepsPreviousSplitInteractive() throws {
        let app = launchIsolatedApp()

        let panes = app.descendants(matching: .any).matching(
            identifier: "terminal-split-pane"
        )
        let row = terminalTabRows(in: app).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        app.typeText("cd /tmp\n")
        XCTAssertTrue(waitForLabel("tmp", on: row))
        app.typeText("cd ~\n")
        XCTAssertTrue(waitForLabel("~", on: row))

        app.typeKey("d", modifierFlags: .command)
        app.typeKey("d", modifierFlags: [.command, .shift])
        expectation(
            for: NSPredicate { _, _ in panes.count == 3 },
            evaluatedWith: nil
        )
        waitForExpectations(timeout: 3)

        app.typeKey("w", modifierFlags: .command)
        expectation(
            for: NSPredicate { _, _ in panes.count == 2 },
            evaluatedWith: nil
        )
        waitForExpectations(timeout: 3)

        app.typeText("cd /tmp\n")
        XCTAssertTrue(waitForLabel("tmp", on: row))
    }

    @MainActor
    func testCommandFFocusesTerminalSearchField() throws {
        let app = launchIsolatedApp()

        app.typeKey("f", modifierFlags: .command)
        let searchField = app.searchFields["terminal-search-field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))
        app.typeText("needle")
        XCTAssertEqual(searchField.value as? String, "needle")
    }

    @MainActor
    func testTerminalUsesHiddenTitleBarSpace() throws {
        let app = launchIsolatedApp()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 3))
        let pane = app.descendants(matching: .any)["terminal-split-pane"]
        XCTAssertTrue(pane.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(pane.frame.minY - window.frame.minY, 2)
    }

    @MainActor
    func testTerminateRunningApplication() throws {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        XCTAssertEqual(app.state, .notRunning)
    }

    @MainActor
    private func launchIsolatedApp() -> XCUIApplication {
        let app = XCUIApplication()
        if app.state != .notRunning { app.terminate() }
        let defaultsSuiteName = "SpaceUITests.\(UUID().uuidString)"
        isolatedApp = app
        isolatedDefaultsSuiteName = defaultsSuiteName
        app.launchEnvironment["SPACE_UI_TEST_DEFAULTS_SUITE"] =
            defaultsSuiteName
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        return app
    }

    @MainActor
    private func terminalTabRows(in app: XCUIApplication) -> XCUIElementQuery {
        app.images.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "terminal-tab-row:"
            )
        )
    }

    @MainActor
    private func waitForLabel(
        _ label: String,
        on element: XCUIElement
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", label),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: 3) == .completed
    }
}
