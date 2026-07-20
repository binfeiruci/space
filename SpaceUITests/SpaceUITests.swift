//
//  SpaceUITests.swift
//  SpaceUITests
//
//  Created by bfrc on 2026/7/15.
//

import Carbon
import XCTest

final class SpaceUITests: XCTestCase {
    private var temporaryContainers: [URL] = []

    override func tearDownWithError() throws {
        for container in temporaryContainers {
            try? FileManager.default.removeItem(at: container)
        }
        temporaryContainers.removeAll()
    }

    @MainActor
    func testNewSplitsDivideTheActivePaneEvenly() throws {
        let (app, _) = try launchIsolatedApp()
        defer { app.terminate() }

        let panes = app.descendants(matching: .any).matching(
            identifier: "terminal-split-pane"
        )
        XCTAssertEqual(panes.count, 1)

        for _ in 0 ..< 3 {
            app.typeKey("d", modifierFlags: .command)
        }
        for _ in 0 ..< 2 {
            app.typeKey("d", modifierFlags: [.command, .shift])
        }

        let paneCount = NSPredicate { _, _ in panes.count == 6 }
        expectation(for: paneCount, evaluatedWith: nil)
        waitForExpectations(timeout: 3)

        let terminalTitle = app.staticTexts["terminal-title"]
        XCTAssertTrue(terminalTitle.exists)
        let windowFrame = app.windows.firstMatch.frame
        let contentFrame = CGRect(
            x: windowFrame.minX,
            y: terminalTitle.frame.maxY,
            width: windowFrame.width,
            height: windowFrame.maxY - terminalTitle.frame.maxY
        )
        let frames = (0 ..< panes.count)
            .map { panes.element(boundBy: $0).frame.intersection(contentFrame) }
        let frameDescription = "frames=\(frames)"
        let widths = frames.map(\.width)
        let heights = frames.map(\.height).sorted()
        XCTAssertEqual(
            widths.min() ?? 0,
            widths.max() ?? 0,
            accuracy: 12,
            frameDescription
        )
        XCTAssertEqual(
            heights[0],
            heights[2],
            accuracy: 12,
            frameDescription
        )
        XCTAssertEqual(
            heights[3],
            heights[5],
            accuracy: 12,
            frameDescription
        )

    }

    @MainActor
    func testTerminalTabsAppearOnlyWhenThereAreMultipleTabs() throws {
        let (app, _) = try launchIsolatedApp()
        defer { app.terminate() }

        let terminalTitle = app.staticTexts["terminal-title"]
        let tabContainer = app.descendants(matching: .any)[
            "terminal-tabs-container"
        ]
        XCTAssertTrue(terminalTitle.waitForExistence(timeout: 3))
        XCTAssertFalse(tabContainer.exists)
        XCTAssertFalse(app.buttons["new-terminal-tab-button"].exists)

        app.typeKey("t", modifierFlags: .command)

        XCTAssertTrue(tabContainer.waitForExistence(timeout: 3))
        XCTAssertFalse(terminalTitle.exists)
        XCTAssertTrue(app.buttons["new-terminal-tab-button"].exists)

        let windowWidth = app.windows.firstMatch.frame.width
        let initialWidth = tabContainer.frame.width

        for _ in 0 ..< 7 {
            app.typeKey("t", modifierFlags: .command)
        }

        let tabFrame = tabContainer.frame
        let widthRatio = tabFrame.width / windowWidth
        XCTAssertGreaterThanOrEqual(tabFrame.height, 20)
        XCTAssertGreaterThan(tabFrame.width, initialWidth)
        XCTAssertLessThanOrEqual(
            widthRatio,
            2.0 / 3.0 + 0.02,
            "The tab bar should not exceed two-thirds of the window width"
        )

    }

    @MainActor
    func testDoubleClickingTerminalTitlePresentsRenameTabSheet() throws {
        let (app, _) = try launchIsolatedApp()
        defer { app.terminate() }

        let terminalTitle = app.staticTexts["terminal-title"]
        XCTAssertTrue(terminalTitle.waitForExistence(timeout: 3))

        terminalTitle.doubleClick()

        XCTAssertTrue(
            app.staticTexts["Rename Tab"].waitForExistence(timeout: 3)
        )
    }

    @MainActor
    func testAppendingWithoutASelectionShowsFeedback() throws {
        let (app, _) = try launchIsolatedApp()
        defer { app.terminate() }

        app.typeKey("m", modifierFlags: [.command, .shift])

        XCTAssertTrue(
            app.staticTexts["No text selected."].waitForExistence(timeout: 3)
        )
    }

    @MainActor
    func testHiddenFolderTracksRefreshingTerminalTitleUntilItStops() throws {
        let (app, folders) = try launchIsolatedApp(
            folderNames: ["First", "Second"]
        )
        defer { app.terminate() }

        let previousInputSource = TISCopyCurrentKeyboardInputSource()
            .takeRetainedValue()
        let englishInputSource = TISCopyCurrentASCIICapableKeyboardInputSource()
            .takeRetainedValue()
        XCTAssertEqual(TISSelectInputSource(englishInputSource), noErr)
        defer {
            _ = TISSelectInputSource(previousInputSource)
        }
        let terminalTitle = app.staticTexts["terminal-title"]
        XCTAssertTrue(terminalTitle.waitForExistence(timeout: 3))
        app.typeText(
            "for i in {1..15}; do printf '\\033]0;%s\\007' \"$i\"; "
                + "sleep 0.2; done"
        )
        app.typeKey(.return, modifierFlags: [])

        func folderRow(at url: URL) -> XCUIElement {
            app.descendants(matching: .any).matching(
                NSPredicate(
                    format: "identifier == %@",
                    "folder-row:\(url.path)"
                )
            ).firstMatch
        }
        folderRow(at: folders[1]).click()

        let firstFolder = folderRow(at: folders[0])
        let activityValue = "Terminal content is updating"
        let activityStarts = NSPredicate(
            format: "value == %@",
            activityValue
        )
        expectation(for: activityStarts, evaluatedWith: firstFolder)
        waitForExpectations(timeout: 3)
        XCTAssertNotEqual(folderRow(at: folders[1]).value as? String, activityValue)

        let activityStops = NSPredicate(
            format: "value != %@",
            activityValue
        )
        expectation(for: activityStops, evaluatedWith: firstFolder)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    func testNoTabFoldersCanBeReorderedByDragging() throws {
        let (app, folders) = try launchIsolatedApp(
            folderNames: ["First", "Second", "Third"]
        )
        defer { app.terminate() }

        let secondIdentifier = "folder-row:\(folders[1].path)"
        let thirdIdentifier = "folder-row:\(folders[2].path)"
        let second = app.descendants(matching: .any)[
            secondIdentifier
        ]
        let third = app.descendants(matching: .any)[
            thirdIdentifier
        ]
        XCTAssertTrue(second.waitForExistence(timeout: 3))
        XCTAssertTrue(third.exists)

        let rows = app.outlines.firstMatch.cells
        let secondRow = rows.containing(
            .any,
            identifier: secondIdentifier
        ).firstMatch
        let thirdRow = rows.containing(
            .any,
            identifier: thirdIdentifier
        ).firstMatch
        XCTAssertTrue(secondRow.exists)
        XCTAssertTrue(thirdRow.exists)
        let source = thirdRow.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        let target = secondRow.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)
        )
        source.press(forDuration: 0.5, thenDragTo: target)

        let moved = NSPredicate { _, _ in third.frame.minY < second.frame.minY }
        expectation(for: moved, evaluatedWith: nil)
        waitForExpectations(timeout: 3)
    }

    @MainActor
    func testSplitDividerCanResizePanes() throws {
        let (app, _) = try launchIsolatedApp()
        defer { app.terminate() }

        app.typeKey("d", modifierFlags: .command)
        let panes = app.descendants(matching: .any).matching(
            identifier: "terminal-split-pane"
        )
        let divider = app.descendants(matching: .any)[
            "terminal-split-divider"
        ]
        XCTAssertTrue(divider.waitForExistence(timeout: 3))
        XCTAssertEqual(panes.count, 2)

        let before = panes.element(boundBy: 0).frame.width
        let start = divider.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        start.press(
            forDuration: 0.1,
            thenDragTo: start.withOffset(CGVector(dx: 120, dy: 0))
        )

        let resized = NSPredicate { _, _ in
            abs(panes.element(boundBy: 0).frame.width - before) > 60
        }
        expectation(for: resized, evaluatedWith: nil)
        waitForExpectations(timeout: 3)
    }

    @MainActor
    func testCommandFFocusesTerminalSearchField() throws {
        let (app, _) = try launchIsolatedApp()
        defer { app.terminate() }

        app.typeKey("f", modifierFlags: .command)

        let searchField = app.textFields["terminal-search-field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))
        app.typeText("needle")
        XCTAssertEqual(searchField.value as? String, "needle")
    }

    @MainActor
    func testTogglingSidebarDoesNotRestoreWindowTitle() throws {
        let (app, _) = try launchIsolatedApp()
        defer { app.terminate() }

        let applicationTitle = app.staticTexts["Space"]
        XCTAssertFalse(applicationTitle.exists)

        app.typeKey("s", modifierFlags: [.command, .option])
        XCTAssertFalse(applicationTitle.exists)

        app.typeKey("s", modifierFlags: [.command, .option])
        XCTAssertFalse(applicationTitle.exists)
    }

    @MainActor
    func testTerminateRunningApplication() throws {
        let app = XCUIApplication()
        if app.state != .notRunning {
            app.terminate()
        }
        XCTAssertEqual(app.state, .notRunning)
    }

    @MainActor
    private func launchIsolatedApp(
        folderNames: [String] = ["Folder"]
    ) throws -> (XCUIApplication, [URL]) {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpaceUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: true
        )
        temporaryContainers.append(container)

        let folders = folderNames.map {
            container.appendingPathComponent($0, isDirectory: true)
        }
        for folder in folders {
            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true
            )
        }

        let app = XCUIApplication()
        if app.state != .notRunning {
            app.terminate()
        }
        app.launchEnvironment["SPACE_UI_TEST_FOLDER_PATHS"] = folders
            .map(\.path)
            .joined(separator: "\n")
        app.launchEnvironment["SPACE_UI_TEST_DEFAULTS_SUITE"] =
            "SpaceUITests.\(UUID().uuidString)"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        return (app, folders)
    }
}
