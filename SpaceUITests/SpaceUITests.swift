//
//  SpaceUITests.swift
//  SpaceUITests
//
//  Created by bfrc on 2026/7/15.
//

import AppKit
import Carbon
import XCTest

final class SpaceUITests: XCTestCase {
    private var temporaryContainers: [URL] = []
    private var previousInputSource: TISInputSource?

    override func setUpWithError() throws {
        try super.setUpWithError()
        previousInputSource = TISCopyCurrentKeyboardInputSource()
            .takeRetainedValue()
        let englishInputSource = TISCopyCurrentASCIICapableKeyboardInputSource()
            .takeRetainedValue()
        XCTAssertEqual(TISSelectInputSource(englishInputSource), noErr)
    }

    override func tearDownWithError() throws {
        if let previousInputSource {
            XCTAssertEqual(TISSelectInputSource(previousInputSource), noErr)
            self.previousInputSource = nil
        }
        for container in temporaryContainers {
            try? FileManager.default.removeItem(at: container)
        }
        temporaryContainers.removeAll()
        try super.tearDownWithError()
    }

    @MainActor
    func testNewSplitsCreateExpectedPanes() throws {
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
    }

    @MainActor
    func testNewTabCreatesATabInTheActiveFolder() throws {
        let (app, _) = try launchIsolatedApp()
        defer { app.terminate() }

        let folderTabRows = app.images.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "terminal-tab-row:"
            )
        )
        let firstTabAppears = NSPredicate { _, _ in folderTabRows.count == 1 }
        expectation(for: firstTabAppears, evaluatedWith: nil)
        waitForExpectations(timeout: 3)

        app.typeKey("t", modifierFlags: .command)

        let standaloneTabRows = app.images.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "standalone-terminal-tab-row:"
            )
        )
        let secondFolderTabAppears = NSPredicate {
            _, _ in folderTabRows.count == 2
        }
        expectation(for: secondFolderTabAppears, evaluatedWith: nil)
        waitForExpectations(timeout: 3)
        XCTAssertEqual(standaloneTabRows.count, 0)
        XCTAssertFalse(app.staticTexts["terminal-title"].exists)
    }

    @MainActor
    func testNewStandaloneTabMenuItemCreatesAStandaloneTab() throws {
        let (app, _) = try launchIsolatedApp()
        defer { app.terminate() }

        app.menuBars.menuBarItems["File"].click()
        let menuItem = app.menuItems["New Standalone Tab"]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 3))
        menuItem.click()

        let standaloneTabRows = app.images.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "standalone-terminal-tab-row:"
            )
        )
        let standaloneTabAppears = NSPredicate {
            _, _ in standaloneTabRows.count == 1
        }
        expectation(for: standaloneTabAppears, evaluatedWith: nil)
        waitForExpectations(timeout: 3)
    }

    @MainActor
    func testSidebarTabsSwitchReliablyOnClick() throws {
        let (app, _) = try launchIsolatedApp()
        defer { app.terminate() }

        let folderTabs = app.images.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "terminal-tab-row:"
            )
        )
        XCTAssertTrue(folderTabs.firstMatch.waitForExistence(timeout: 3))
        app.typeKey("t", modifierFlags: .command)
        let secondTabAppears = NSPredicate { _, _ in folderTabs.count == 2 }
        expectation(for: secondTabAppears, evaluatedWith: nil)
        waitForExpectations(timeout: 3)

        let firstTab = element(
            in: app.images,
            identifier: folderTabs.element(boundBy: 0).identifier
        )
        let secondTab = element(
            in: app.images,
            identifier: folderTabs.element(boundBy: 1).identifier
        )

        for _ in 0 ..< 5 {
            firstTab.click()
            XCTAssertEqual(firstTab.value as? String, "Selected")
            secondTab.click()
            XCTAssertEqual(secondTab.value as? String, "Selected")
        }
    }

    @MainActor
    func testFolderExpansionStatesAreIndependent() throws {
        let (app, _) = try launchIsolatedApp(
            folderNames: ["First", "Second"]
        )
        defer { app.terminate() }

        let folderTabs = app.images.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "terminal-tab-row:"
            )
        )
        XCTAssertEqual(folderTabs.count, 1)
        let firstTabIdentifier = folderTabs.firstMatch.identifier

        openRecentFolder(named: "Second", in: app)

        let bothFoldersRemainExpanded = NSPredicate {
            _, _ in folderTabs.count == 2
        }
        expectation(for: bothFoldersRemainExpanded, evaluatedWith: nil)
        waitForExpectations(timeout: 3)
        let secondTabIdentifier = try XCTUnwrap(
            (0..<folderTabs.count)
                .map { folderTabs.element(boundBy: $0).identifier }
                .first { $0 != firstTabIdentifier }
        )

        let disclosure = app.disclosureTriangles.firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 3))
        disclosure.click()

        let firstFolderTabDisappears = NSPredicate {
            _, _ in !self.element(
                in: app.images,
                identifier: firstTabIdentifier
            ).exists
        }
        expectation(for: firstFolderTabDisappears, evaluatedWith: nil)
        waitForExpectations(timeout: 3)
        XCTAssertEqual(folderTabs.count, 1)
        XCTAssertTrue(
            element(
                in: app.images,
                identifier: secondTabIdentifier
            ).exists
        )
    }

    @MainActor
    func testFirstLaunchCreatesAStandaloneHomeTab() throws {
        let (app, _) = try launchIsolatedApp(folderNames: [])
        defer { app.terminate() }

        let standaloneTab = app.images.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "standalone-terminal-tab-row:"
            )
        ).firstMatch
        XCTAssertTrue(standaloneTab.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Other Folders"].exists)
        openRecentMenu(in: app)
        XCTAssertTrue(app.menuItems["No Recent Folders"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testReopeningAfterClosingLastTabCreatesANewTab() throws {
        let (app, _) = try launchIsolatedApp(folderNames: [])
        defer { app.terminate() }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 3))
        let runningApplication = try XCTUnwrap(
            NSRunningApplication.runningApplications(
                withBundleIdentifier: "bfrc.Space"
            ).first
        )
        let applicationURL = try XCTUnwrap(runningApplication.bundleURL)

        let tab = app.images.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "standalone-terminal-tab-row:"
            )
        ).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 3))
        tab.rightClick()
        let closeTabItem = app.menuItems["Close Tab"]
        XCTAssertTrue(closeTabItem.waitForExistence(timeout: 3))
        closeTabItem.click()

        let windowClosed = NSPredicate { _, _ in !window.exists }
        expectation(for: windowClosed, evaluatedWith: nil)
        waitForExpectations(timeout: 3)

        let reopenFinished = expectation(description: "Application reopened")
        NSWorkspace.shared.openApplication(
            at: applicationURL,
            configuration: .init()
        ) { _, error in
            XCTAssertNil(error)
            reopenFinished.fulfill()
        }
        waitForExpectations(timeout: 3)
        let reopenedWindow = app.windows.firstMatch
        XCTAssertTrue(reopenedWindow.waitForExistence(timeout: 3))
        let reopenedTab = app.images.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "standalone-terminal-tab-row:"
            )
        ).firstMatch
        XCTAssertTrue(reopenedTab.waitForExistence(timeout: 3))
    }

    @MainActor
    func testCollapsedFolderShowsCompletedTitleActivityAsUnread() throws {
        let (app, folders) = try launchIsolatedApp(
            folderNames: ["First", "Second"]
        )
        defer { app.terminate() }

        let terminalPane = app.descendants(matching: .any)[
            "terminal-split-pane"
        ]
        XCTAssertTrue(terminalPane.waitForExistence(timeout: 3))
        let folderTabs = app.images.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "terminal-tab-row:"
            )
        )
        XCTAssertEqual(folderTabs.count, 1)
        let refreshingTabIdentifier = folderTabs.firstMatch.identifier
        app.typeText(
            "for i in {1..30}; do printf '\\033]0;%s\\007' \"$i\"; "
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
        let firstFolder = folderRow(at: folders[0])
        let initialDisclosure = row(
            in: app.disclosureTriangles,
            nearestTo: firstFolder
        )
        XCTAssertTrue(initialDisclosure.waitForExistence(timeout: 3))
        initialDisclosure.click()
        openRecentFolder(named: "Second", in: app)

        let activityValue = "Terminal content is updating"
        let activityStarts = NSPredicate(
            format: "value == %@",
            activityValue
        )
        expectation(for: activityStarts, evaluatedWith: firstFolder)
        waitForExpectations(timeout: 3)

        let unreadValue = "Unread terminal activity"
        let activityBecomesUnread = NSPredicate(
            format: "value == %@",
            unreadValue
        )
        expectation(for: activityBecomesUnread, evaluatedWith: firstFolder)
        waitForExpectations(timeout: 8)

        let disclosureTriangle = row(
            in: app.disclosureTriangles,
            nearestTo: firstFolder
        )
        XCTAssertTrue(disclosureTriangle.exists)
        disclosureTriangle.click()
        let folderUnreadClears = NSPredicate(
            format: "value != %@",
            unreadValue
        )
        expectation(for: folderUnreadClears, evaluatedWith: firstFolder)
        let refreshingTab = element(
            in: app.images,
            identifier: refreshingTabIdentifier
        )
        expectation(
            for: NSPredicate(format: "value == %@", unreadValue),
            evaluatedWith: refreshingTab
        )
        waitForExpectations(timeout: 3)
    }

    @MainActor
    func testBackgroundTabAgentAttentionBringsSpaceToForeground() throws {
        let (app, _) = try launchIsolatedApp()
        defer { app.terminate() }

        let terminalPane = app.descendants(matching: .any)[
            "terminal-split-pane"
        ]
        XCTAssertTrue(terminalPane.waitForExistence(timeout: 3))
        let folderTabs = app.images.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "terminal-tab-row:"
            )
        )
        XCTAssertEqual(folderTabs.count, 1)
        let notifyingTabIdentifier = folderTabs.firstMatch.identifier
        app.typeText(
            "(sleep 3; printf '\\033]777;notify;Codex;"
                + "Approval needed\\007') &"
        )
        app.typeKey(.return, modifierFlags: [])
        app.typeKey("t", modifierFlags: .command)
        let secondTabAppears = NSPredicate { _, _ in folderTabs.count == 2 }
        expectation(for: secondTabAppears, evaluatedWith: nil)
        waitForExpectations(timeout: 3)

        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 3))
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 6))
        XCTAssertEqual(
            element(
                in: app.images,
                identifier: notifyingTabIdentifier
            ).value as? String,
            "Selected"
        )
    }

    @MainActor
    func testOpenRecentIncludesOpenAndClosedFolders() throws {
        let (app, folders) = try launchIsolatedApp(
            folderNames: ["First", "Second", "Third"]
        )
        defer { app.terminate() }

        let first = element(
            in: app.descendants(matching: .any),
            identifier: "folder-row:\(folders[0].path)"
        )
        let second = element(
            in: app.descendants(matching: .any),
            identifier: "folder-row:\(folders[1].path)"
        )
        let third = element(
            in: app.descendants(matching: .any),
            identifier: "folder-row:\(folders[2].path)"
        )
        XCTAssertTrue(first.waitForExistence(timeout: 3))
        XCTAssertFalse(second.exists)
        XCTAssertFalse(third.exists)

        openRecentMenu(in: app)
        XCTAssertTrue(app.menuItems["First"].exists)
        XCTAssertTrue(app.menuItems["Second"].exists)
        XCTAssertTrue(app.menuItems["Third"].exists)
        app.menuItems["Second"].click()

        XCTAssertTrue(second.waitForExistence(timeout: 3))
        openRecentMenu(in: app)
        XCTAssertTrue(app.menuItems["First"].exists)
        XCTAssertTrue(app.menuItems["Second"].exists)
        XCTAssertTrue(app.menuItems["Third"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testOpenRecentStaysVisibleDuringTerminalTitleUpdates() throws {
        let (app, _) = try launchIsolatedApp(
            folderNames: ["First", "Second"]
        )
        defer { app.terminate() }

        app.typeText(
            "for i in {1..30}; do printf '\\033]0;%s\\007' \"$i\"; "
                + "sleep 0.1; done"
        )
        app.typeKey(.return, modifierFlags: [])

        openRecentMenu(in: app)
        let first = app.menuItems["First"]
        XCTAssertTrue(first.exists)
        XCTAssertTrue(app.menuItems["Second"].exists)
        let menuDisappears = expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: first
        )
        menuDisappears.isInverted = true
        waitForExpectations(timeout: 1)
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testRemovedFolderStaysInOpenRecent() throws {
        let (app, folders) = try launchIsolatedApp(
            folderNames: ["First", "Second"]
        )
        defer { app.terminate() }

        openRecentFolder(named: "Second", in: app)
        let second = element(
            in: app.descendants(matching: .any),
            identifier: "folder-row:\(folders[1].path)"
        )
        XCTAssertTrue(second.waitForExistence(timeout: 3))
        second.rightClick()
        let removeFolder = app.menuItems["Remove Folder"]
        XCTAssertTrue(removeFolder.waitForExistence(timeout: 3))
        removeFolder.click()
        let secondDisappears = NSPredicate(format: "exists == false")
        expectation(for: secondDisappears, evaluatedWith: second)
        waitForExpectations(timeout: 3)

        openRecentMenu(in: app)
        XCTAssertTrue(app.menuItems["Second"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testTabsCanBeReorderedByDragging() throws {
        let (app, _) = try launchIsolatedApp(folderNames: [])
        defer { app.terminate() }

        let tabs = app.images.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "standalone-terminal-tab-row:"
            )
        )
        XCTAssertEqual(tabs.count, 1)
        app.typeKey("t", modifierFlags: .command)
        dragSecondTabBeforeFirst(tabs, in: app)
    }

    @MainActor
    func testFolderTabsCanBeReorderedByDragging() throws {
        let (app, folders) = try launchIsolatedApp()
        defer { app.terminate() }

        let folder = element(
            in: app.descendants(matching: .any),
            identifier: "folder-row:\(folders[0].path)"
        )
        XCTAssertTrue(folder.waitForExistence(timeout: 3))
        folder.rightClick()
        let newTabItems = app.menuItems.matching(identifier: "New Tab")
        let newTabItem = (0..<newTabItems.count)
            .map { newTabItems.element(boundBy: $0) }
            .first(where: \.isHittable)
        XCTAssertNotNil(newTabItem)
        guard let newTabItem else { return }
        newTabItem.click()

        let tabs = app.images.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "terminal-tab-row:"
            )
        )
        dragSecondTabBeforeFirst(tabs, in: app)
    }

    @MainActor
    private func dragSecondTabBeforeFirst(
        _ tabs: XCUIElementQuery,
        in app: XCUIApplication
    ) {
        let twoTabsExist = NSPredicate { _, _ in tabs.count == 2 }
        expectation(for: twoTabsExist, evaluatedWith: nil)
        waitForExpectations(timeout: 3)

        let firstIdentifier = tabs.element(boundBy: 0).identifier
        let secondIdentifier = tabs.element(boundBy: 1).identifier
        let first = element(in: app.images, identifier: firstIdentifier)
        let second = element(in: app.images, identifier: secondIdentifier)
        let rows = app.outlines.firstMatch.cells
        let firstRow = row(in: rows, nearestTo: first)
        let secondRow = row(in: rows, nearestTo: second)
        XCTAssertTrue(firstRow.exists)
        XCTAssertTrue(secondRow.exists)

        let source = secondRow.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        let target = firstRow.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)
        )
        source.press(forDuration: 0.5, thenDragTo: target)

        let moved = NSPredicate { _, _ in second.frame.minY < first.frame.minY }
        expectation(for: moved, evaluatedWith: nil)
        waitForExpectations(timeout: 3)

        let draggedTabIsVisibleAgain = NSPredicate(format: "hittable == true")
        expectation(for: draggedTabIsVisibleAgain, evaluatedWith: second)
        waitForExpectations(timeout: 3)
    }

    @MainActor
    private func openRecentFolder(
        named name: String,
        in app: XCUIApplication
    ) {
        openRecentMenu(in: app)
        let folder = app.menuItems[name]
        XCTAssertTrue(folder.waitForExistence(timeout: 3))
        folder.click()
    }

    @MainActor
    private func openRecentMenu(in app: XCUIApplication) {
        app.menuBars.menuBarItems["File"].click()
        let openRecent = app.menuItems["Open Recent"]
        XCTAssertTrue(openRecent.waitForExistence(timeout: 3))
        openRecent.click()
    }

    @MainActor
    private func element(
        in query: XCUIElementQuery,
        identifier: String
    ) -> XCUIElement {
        query.matching(identifierPredicate(identifier)).firstMatch
    }

    private func identifierPredicate(_ identifier: String) -> NSPredicate {
        NSPredicate(format: "identifier == %@", identifier)
    }

    @MainActor
    private func row(
        in rows: XCUIElementQuery,
        nearestTo element: XCUIElement
    ) -> XCUIElement {
        let elements = (0 ..< rows.count).map {
            rows.element(boundBy: $0)
        }
        return elements.min {
            abs($0.frame.midY - element.frame.midY)
                < abs($1.frame.midY - element.frame.midY)
        } ?? rows.element(boundBy: rows.count)
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

        let searchField = app.searchFields["terminal-search-field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(searchField.frame.width, 150)
        let searchBar = app.descendants(matching: .any)["terminal-search-bar"]
        XCTAssertTrue(searchBar.waitForExistence(timeout: 3))
        XCTAssertLessThan(searchBar.frame.height, 60)
        app.typeText("needle")
        XCTAssertEqual(searchField.value as? String, "needle")
    }

    @MainActor
    func testTerminalUsesHiddenTitleBarSpace() throws {
        let (app, _) = try launchIsolatedApp()
        defer { app.terminate() }

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 3))
        let terminalPane = app.descendants(matching: .any)[
            "terminal-split-pane"
        ]
        XCTAssertTrue(terminalPane.waitForExistence(timeout: 3))
        XCTAssertLessThanOrEqual(
            terminalPane.frame.minY - window.frame.minY,
            2
        )
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
