import XCTest

final class StudioUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    func testNewProjectIsEmptyAndKeyboardDoesNotBlockBack() {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--uitesting-reset"]; app.launch()
        XCTAssertTrue(app.buttons["newProject"].waitForExistence(timeout: 20)); app.buttons["newProject"].tap()
        XCTAssertTrue(app.textFields["projectName"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["exportVideo"].isEnabled)
        let preview = app.descendants(matching: .any).matching(identifier: "videoPreview").firstMatch
        let width = preview.frame.width
        app.textFields["projectName"].tap()
        XCTAssertEqual(preview.frame.width, width, accuracy: 2, "Keyboard must not switch portrait into landscape layout")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["newProject"].waitForExistence(timeout: 10))
    }
    func testEditorPlaybackLandscapeUndoExportAndRelaunch() {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--uitesting-reset", "--uitesting-fixture"]; app.launch()
        XCTAssertTrue(app.staticTexts["Kiểm thử Studio"].waitForExistence(timeout: 30)); app.staticTexts["Kiểm thử Studio"].tap()
        let play = app.buttons["playPause"]
        XCTAssertTrue(play.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 20)
        play.tap()
        app.buttons["saveProject"].tap()
        let time = app.staticTexts["playheadTime"]
        let advancing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != '00:00.0'"), object: time)
        let result = XCTWaiter.wait(for: [advancing], timeout: 10)
        XCTAssertEqual(result, .completed, app.staticTexts["playerDebug"].label)
        if play.label == "Tạm dừng" { play.tap() }
        app.buttons["duplicateClip"].tap()
        XCTAssertEqual(app.staticTexts["clipCount"].label, "2 đoạn")
        app.buttons["clip_1"].tap()
        expectation(for: NSPredicate(format: "label == '00:08.0'"), evaluatedWith: time); waitForExpectations(timeout: 10)
        app.buttons["clip_0"].tap()
        expectation(for: NSPredicate(format: "label == '00:00.0'"), evaluatedWith: time); waitForExpectations(timeout: 10)
        app.buttons["undo"].tap(); XCTAssertEqual(app.staticTexts["clipCount"].label, "1 đoạn")
        app.buttons["redo"].tap(); XCTAssertEqual(app.staticTexts["clipCount"].label, "2 đoạn")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["exportVideo"].waitForExistence(timeout: 10))
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Landscape Pro"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertEqual(app.staticTexts["clipCount"].label, "2 đoạn")
        let export = app.buttons["exportVideo"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: export); waitForExpectations(timeout: 20)
        export.tap()
        XCTAssertTrue(app.staticTexts["Đã xuất MP4 thành công"].waitForExistence(timeout: 40))
        XCUIDevice.shared.orientation = .portrait
        let portrait = XCTAttachment(screenshot: app.screenshot()); portrait.name = "Portrait editor"; portrait.lifetime = .keepAlways; add(portrait)
        app.terminate(); app.launchArguments = ["--uitesting"]; app.launch()
        XCTAssertTrue(app.staticTexts["Kiểm thử Studio"].waitForExistence(timeout: 20)); app.staticTexts["Kiểm thử Studio"].tap()
        XCTAssertEqual(app.staticTexts["clipCount"].label, "2 đoạn")
    }
}
