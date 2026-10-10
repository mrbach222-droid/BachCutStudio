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
        app.descendants(matching: .any).matching(identifier: "clip_1").firstMatch.tap()
        expectation(for: NSPredicate(format: "label == '00:08.0'"), evaluatedWith: time); waitForExpectations(timeout: 10)
        app.descendants(matching: .any).matching(identifier: "clip_0").firstMatch.tap()
        expectation(for: NSPredicate(format: "label == '00:00.0'"), evaluatedWith: time); waitForExpectations(timeout: 10)
        app.buttons["undo"].tap(); XCTAssertEqual(app.staticTexts["clipCount"].label, "1 đoạn")
        app.buttons["redo"].tap(); XCTAssertEqual(app.staticTexts["clipCount"].label, "2 đoạn")
        rotateAndSettle(app, landscape: true)
        XCTAssertTrue(app.buttons["exportVideo"].waitForExistence(timeout: 10))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Landscape Pro"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertEqual(app.staticTexts["clipCount"].label, "2 đoạn")
        let export = app.buttons["exportVideo"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: export); waitForExpectations(timeout: 20)
        export.tap()
        XCTAssertTrue(app.buttons["confirmExport"].waitForExistence(timeout: 10))
        app.buttons["exportResolution"].tap(); app.buttons["480p"].tap()
        let settings = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); settings.name = "Export options"; settings.lifetime = .keepAlways; add(settings)
        app.buttons["confirmExport"].tap()
        XCTAssertTrue(app.staticTexts["Đã xuất MP4 thành công"].waitForExistence(timeout: 40))
        rotateAndSettle(app, landscape: false)
        let portrait = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); portrait.name = "Portrait editor"; portrait.lifetime = .keepAlways; add(portrait)
        app.terminate(); app.launchArguments = ["--uitesting"]; app.launch()
        XCTAssertTrue(app.staticTexts["Kiểm thử Studio"].waitForExistence(timeout: 20)); app.staticTexts["Kiểm thử Studio"].tap()
        XCTAssertEqual(app.staticTexts["clipCount"].label, "2 đoạn")
    }

    func testCenteredScrubbingAndLongPressReorder() {
        let app = XCUIApplication(); app.launchArguments = ["--uitesting", "--uitesting-reset", "--uitesting-fixture"]; app.launch()
        XCTAssertTrue(app.staticTexts["Kiểm thử Studio"].waitForExistence(timeout: 30)); app.staticTexts["Kiểm thử Studio"].tap()
        let play = app.buttons["playPause"]
        XCTAssertTrue(play.waitForExistence(timeout: 15))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 20)
        let timeline = app.collectionViews["centeredTimeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 10))
        let time = app.staticTexts["playheadTime"]
        let start = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.45))
        let end = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.45))
        start.press(forDuration: 0.05, thenDragTo: end)
        XCTAssertNotEqual(time.label, "00:00.0", "Moving the timeline must scrub the preview")
        XCTAssertEqual(play.label, "Phát")
        app.buttons["duplicateClip"].tap()
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 20)
        // Reveal the second clip at the center, then hold its thumbnail and drag before the first.
        app.descendants(matching: .any).matching(identifier: "clip_1").firstMatch.tap()
        let timeBeforeReorder = time.label
        XCTAssertNotEqual(timeBeforeReorder, "00:00.0", "Selection must move to the second clip before reordering")
        let second = app.descendants(matching: .any).matching(identifier: "clip_1").firstMatch
        let source = second.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
        let destination = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.45))
        source.press(forDuration: 0.6, thenDragTo: destination)
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 20)
        XCTAssertEqual(app.staticTexts["clipCount"].label, "2 đoạn")
        XCTAssertTrue(app.buttons["undo"].isEnabled)
        XCTAssertEqual(time.label, timeBeforeReorder, "Long-press reorder must preserve the fixed center playhead")
        app.buttons["undo"].tap()
        XCTAssertEqual(app.staticTexts["clipCount"].label, "2 đoạn", "Reorder must be one undo action")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Centered timeline after drag"; shot.lifetime = .keepAlways; add(shot)
    }

    func rotateAndSettle(_ app: XCUIApplication, landscape: Bool) {
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        let window = app.windows.firstMatch
        var previous = CGRect.zero
        var stableSamples = 0
        for _ in 0..<80 {
            let frame = window.frame
            let matches = landscape ? frame.width > frame.height : frame.height > frame.width
            stableSamples = matches && frame == previous ? stableSamples + 1 : 0
            if stableSamples >= 5 {
                XCTAssertTrue(app.buttons["exportVideo"].isHittable, "Export must stay reachable after rotation")
                return
            }
            previous = frame
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("Window did not settle after rotation: \(window.frame)")
    }
}
