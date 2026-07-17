//
//  SpaceUITests.swift
//  SpaceUITests
//
//  Created by bfrc on 2026/7/15.
//

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
            "Tab 栏不应超过窗口宽度的 2/3"
        )

    }

    @MainActor
    func testDoubleClickingSingleTerminalTitlePresentsRenameSheet() throws {
        let (app, _) = try launchIsolatedApp()
        defer { app.terminate() }

        let terminalTitle = app.staticTexts["terminal-title"]
        XCTAssertTrue(terminalTitle.waitForExistence(timeout: 3))

        terminalTitle.doubleClick()

        XCTAssertTrue(
            app.staticTexts["重命名终端"].waitForExistence(timeout: 3)
        )
    }

    @MainActor
    func testFoldersCanBeReorderedByDragging() throws {
        let (app, folders) = try launchIsolatedApp(
            folderNames: ["First", "Second", "Third"]
        )
        defer { app.terminate() }

        let first = app.descendants(matching: .any)[
            "folder-row:\(folders[0].path)"
        ]
        let third = app.descendants(matching: .any)[
            "folder-row:\(folders[2].path)"
        ]
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        XCTAssertTrue(third.exists)

        let rows = app.outlines.firstMatch.cells
        XCTAssertEqual(rows.count, 3)
        let firstRow = rows.element(boundBy: 0)
        let thirdRow = rows.element(boundBy: 2)
        let source = thirdRow.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        let target = firstRow.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)
        )
        source.press(forDuration: 0.5, thenDragTo: target)

        let moved = NSPredicate { _, _ in third.frame.minY < first.frame.minY }
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
        folderNames: [String] = ["Workspace"]
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
        app.launchEnvironment["SPACE_UI_TEST_ROOT_PATHS"] = folders
            .map(\.path)
            .joined(separator: "\n")
        app.launchEnvironment["SPACE_UI_TEST_DEFAULTS_SUITE"] =
            "SpaceUITests.\(UUID().uuidString)"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        return (app, folders)
    }
}
