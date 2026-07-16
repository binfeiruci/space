//
//  SpaceUITests.swift
//  SpaceUITests
//
//  Created by bfrc on 2026/7/15.
//

import XCTest

final class SpaceUITests: XCTestCase {
    @MainActor
    func testTerminateRunningApplication() throws {
        let app = XCUIApplication()
        if app.state != .notRunning {
            app.terminate()
        }
        XCTAssertEqual(app.state, .notRunning)
    }
}
