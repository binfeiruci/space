import AppKit
import Carbon
import XCTest

final class SpaceUITests: XCTestCase {
    private var previousInputSource: TISInputSource?

    override func setUpWithError() throws {
        try super.setUpWithError()
        previousInputSource = TISCopyCurrentKeyboardInputSource()
            .takeRetainedValue()
        let english = TISCopyCurrentASCIICapableKeyboardInputSource()
            .takeRetainedValue()
        XCTAssertEqual(TISSelectInputSource(english), noErr)
    }

    override func tearDownWithError() throws {
        if let previousInputSource {
            XCTAssertEqual(TISSelectInputSource(previousInputSource), noErr)
            self.previousInputSource = nil
        }
        try super.tearDownWithError()
    }

    @MainActor
    func testNewTabCreatesAnotherTab() throws {
        let app = launchIsolatedApp()
        defer { app.terminate() }

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
    func testNewSplitsCreateExpectedPanes() throws {
        let app = launchIsolatedApp()
        defer { app.terminate() }

        let panes = app.descendants(matching: .any).matching(
            identifier: "terminal-split-pane"
        )
        XCTAssertEqual(panes.count, 1)
        app.typeKey("d", modifierFlags: .command)
        app.typeKey("d", modifierFlags: [.command, .shift])

        expectation(
            for: NSPredicate { _, _ in panes.count == 3 },
            evaluatedWith: nil
        )
        waitForExpectations(timeout: 3)
    }

    @MainActor
    func testCommandFFocusesTerminalSearchField() throws {
        let app = launchIsolatedApp()
        defer { app.terminate() }

        app.typeKey("f", modifierFlags: .command)
        let searchField = app.searchFields["terminal-search-field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))
        app.typeText("needle")
        XCTAssertEqual(searchField.value as? String, "needle")
    }

    @MainActor
    func testTerminalUsesHiddenTitleBarSpace() throws {
        let app = launchIsolatedApp()
        defer { app.terminate() }

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
        app.launchEnvironment["SPACE_UI_TEST_DEFAULTS_SUITE"] =
            "SpaceUITests.\(UUID().uuidString)"
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
}
