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
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 20)
        app.descendants(matching: .any).matching(identifier: "clip_1").firstMatch.tap()
        expectation(for: NSPredicate(format: "label == '00:08.0'"), evaluatedWith: time); waitForExpectations(timeout: 10)
        XCTAssertEqual(play.label, "Phát", "Selecting a clip must pause at its edit point")
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
        // Let the native picker dismissal finish before preserving its image.
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
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
        let originalFirstID = app.descendants(matching: .any).matching(identifier: "clip_0").firstMatch.value as? String
        let originalSecondID = app.descendants(matching: .any).matching(identifier: "clip_1").firstMatch.value as? String
        XCTAssertNotNil(originalFirstID); XCTAssertNotNil(originalSecondID)
        XCTAssertNotEqual(originalFirstID, originalSecondID)
        let timeBeforeReorder = time.label
        XCTAssertNotEqual(timeBeforeReorder, "00:00.0", "Selection must move to the second clip before reordering")
        let second = app.descendants(matching: .any).matching(identifier: "clip_1").firstMatch
        let source = second.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
        let destination = timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.45))
        source.press(forDuration: 0.6, thenDragTo: destination)
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 20)
        XCTAssertEqual(app.staticTexts["clipCount"].label, "2 đoạn")
        XCTAssertTrue(app.buttons["undo"].isEnabled)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "clip_0").firstMatch.value as? String, originalSecondID,
                       "Long-press drag must actually put the second source clip before the first")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "clip_1").firstMatch.value as? String, originalFirstID)
        XCTAssertEqual(time.label, timeBeforeReorder, "Long-press reorder must preserve the fixed center playhead")
        app.buttons["undo"].tap()
        XCTAssertEqual(app.staticTexts["clipCount"].label, "2 đoạn", "Reorder must be one undo action")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "clip_0").firstMatch.value as? String, originalFirstID)
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "clip_1").firstMatch.value as? String, originalSecondID)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Centered timeline after drag"; shot.lifetime = .keepAlways; add(shot)
    }

    func testSecondaryTracksDragUndoPersistenceAndRotation() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-reset", "--uitesting-fixture", "--uitesting-multitrack"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Kiểm thử Studio"].waitForExistence(timeout: 30))
        let home = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); home.name = "Project library"; home.lifetime = .keepAlways; add(home)
        app.staticTexts["Kiểm thử Studio"].tap()
        let play = app.buttons["playPause"]
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 20)
        let audio = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'audioTrack_' ")).firstMatch
        let overlay = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'overlayTrack_' ")).firstMatch
        XCTAssertTrue(audio.waitForExistence(timeout: 10)); XCTAssertTrue(overlay.exists)
        let audioStart = audio.value as? String
        XCTAssertEqual(audioStart, "00:01.0")
        let time = app.staticTexts["playheadTime"]
        let positionBeforeDrag = time.label
        let from = audio.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: -24, dy: 0)))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 20)
        let movedAudio = audio.value as? String
        XCTAssertNotEqual(movedAudio, audioStart, "Dragging the music block must commit its offset")
        XCTAssertEqual(time.label, positionBeforeDrag, "Secondary-track drag must hold the central playhead")
        app.buttons["undo"].tap()
        XCTAssertEqual(audio.value as? String, audioStart)
        app.buttons["redo"].tap()
        XCTAssertEqual(audio.value as? String, movedAudio)
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: play); waitForExpectations(timeout: 20)
        let originalOverlay = overlay.value as? String
        let overlayFrom = overlay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        overlayFrom.press(forDuration: 0.05, thenDragTo: overlayFrom.withOffset(CGVector(dx: 24, dy: 0)))
        waitForReady(app)
        let movedOverlay = overlay.value as? String
        XCTAssertNotEqual(movedOverlay, originalOverlay, "Dragging the overlay block must commit its offset")
        XCTAssertEqual(time.label, positionBeforeDrag)
        let portrait = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); portrait.name = "Portrait multi-track editor"; portrait.lifetime = .keepAlways; add(portrait)
        rotateAndSettle(app, landscape: true)
        XCTAssertEqual(audio.value as? String, movedAudio); XCTAssertEqual(overlay.value as? String, movedOverlay)
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); landscape.name = "Landscape multi-track editor"; landscape.lifetime = .keepAlways; add(landscape)
        app.terminate(); app.launchArguments = ["--uitesting"]; app.launch()
        XCTAssertTrue(app.staticTexts["Kiểm thử Studio"].waitForExistence(timeout: 20)); app.staticTexts["Kiểm thử Studio"].tap()
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["playPause"]); waitForExpectations(timeout: 20)
        XCTAssertEqual(audio.value as? String, movedAudio)
        XCTAssertEqual(overlay.value as? String, movedOverlay)
    }

    func testSourceSelectionUndoAndRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-reset", "--uitesting-fixture", "--uitesting-multitrack"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Kiểm thử Studio"].waitForExistence(timeout: 30)); app.staticTexts["Kiểm thử Studio"].tap()
        waitForReady(app)
        let audio = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'audioTrack_' ")).firstMatch
        let overlay = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'overlayTrack_' ")).firstMatch
        audio.tap()
        let sourceForward = app.buttons["sourceForward"]
        XCTAssertTrue(sourceForward.waitForExistence(timeout: 5))
        for _ in 0..<3 { sourceForward.tap() }
        XCTAssertEqual(app.staticTexts["sourceStartTime"].label, "00:00.3")
        app.buttons["sourceBack"].tap(); XCTAssertEqual(app.staticTexts["sourceStartTime"].label, "00:00.2")
        sourceForward.tap(); XCTAssertEqual(app.staticTexts["sourceStartTime"].label, "00:00.3")
        app.buttons["trackForward"].tap(); app.buttons["trackForward"].tap()
        app.buttons["trackBack"].tap(); app.buttons["trackForward"].tap()
        XCTAssertEqual(app.staticTexts["sourceStartTime"].label, "00:00.3", "Timeline controls must not change the selected source interval")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "Music source selection"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["applyTrackTiming"].tap(); waitForReady(app)
        XCTAssertEqual(audio.value as? String, "00:01.2")
        app.buttons["undo"].tap(); waitForReady(app)
        XCTAssertEqual(audio.value as? String, "00:01.0")
        audio.tap(); XCTAssertEqual(app.staticTexts["sourceStartTime"].label, "00:00.0"); app.buttons["Hủy"].tap()
        app.buttons["redo"].tap(); waitForReady(app)
        XCTAssertEqual(audio.value as? String, "00:01.2")
        audio.tap(); XCTAssertEqual(app.staticTexts["sourceStartTime"].label, "00:00.3"); app.buttons["Hủy"].tap()
        overlay.tap(); XCTAssertTrue(sourceForward.waitForExistence(timeout: 5))
        sourceForward.tap(); sourceForward.tap()
        XCTAssertEqual(app.staticTexts["sourceStartTime"].label, "00:00.2")
        app.buttons["applyTrackTiming"].tap(); waitForReady(app)
        app.terminate(); app.launchArguments = ["--uitesting"]; app.launch()
        XCTAssertTrue(app.staticTexts["Kiểm thử Studio"].waitForExistence(timeout: 20)); app.staticTexts["Kiểm thử Studio"].tap(); waitForReady(app)
        audio.tap(); XCTAssertEqual(app.staticTexts["sourceStartTime"].label, "00:00.3"); app.buttons["Hủy"].tap()
        overlay.tap(); XCTAssertEqual(app.staticTexts["sourceStartTime"].label, "00:00.2"); app.buttons["Hủy"].tap()
    }

    func testDirectVideoEdgeTrimUndoRotationAndRelaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-reset", "--uitesting-fixture"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Kiểm thử Studio"].waitForExistence(timeout: 30)); app.staticTexts["Kiểm thử Studio"].tap()
        waitForReady(app)
        let start = app.descendants(matching: .any).matching(identifier: "trimVideoStart").firstMatch
        let end = app.descendants(matching: .any).matching(identifier: "trimVideoEnd").firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10)); XCTAssertTrue(end.isHittable)
        let timeBefore = app.staticTexts["playheadTime"].label
        dragHandle(end, points: -40); waitForReady(app)
        let trimmedEnd = end.value as? String
        XCTAssertNotEqual(trimmedEnd, "00:08.0", "The right grip must change the source out-point")
        XCTAssertEqual(start.value as? String, "00:00.0")
        XCTAssertEqual(app.staticTexts["playheadTime"].label, timeBefore)
        app.buttons["undo"].tap(); waitForReady(app)
        XCTAssertEqual(end.value as? String, "00:08.0", "One undo must reverse the entire drag")
        app.buttons["redo"].tap(); waitForReady(app); XCTAssertEqual(end.value as? String, trimmedEnd)
        dragHandle(start, points: 30); waitForReady(app)
        let trimmedStart = start.value as? String
        XCTAssertNotEqual(trimmedStart, "00:00.0"); XCTAssertEqual(end.value as? String, trimmedEnd)
        XCTAssertEqual(app.staticTexts["clipCount"].label, "1 đoạn")
        let portrait = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); portrait.name = "Direct video trim portrait"; portrait.lifetime = .keepAlways; add(portrait)
        rotateAndSettle(app, landscape: true)
        XCTAssertEqual(start.value as? String, trimmedStart); XCTAssertEqual(end.value as? String, trimmedEnd)
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); landscape.name = "Direct video trim landscape"; landscape.lifetime = .keepAlways; add(landscape)
        app.buttons["undo"].tap(); waitForReady(app)
        XCTAssertEqual(start.value as? String, "00:00.0"); XCTAssertEqual(end.value as? String, trimmedEnd)
        app.buttons["redo"].tap(); waitForReady(app)
        app.terminate(); app.launchArguments = ["--uitesting"]; app.launch()
        XCTAssertTrue(app.staticTexts["Kiểm thử Studio"].waitForExistence(timeout: 20)); app.staticTexts["Kiểm thử Studio"].tap(); waitForReady(app)
        XCTAssertEqual(start.value as? String, trimmedStart); XCTAssertEqual(end.value as? String, trimmedEnd)
    }

    func testDirectSecondaryEdgeTrimUndoAndPersistence() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-reset", "--uitesting-fixture", "--uitesting-multitrack"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Kiểm thử Studio"].waitForExistence(timeout: 30)); app.staticTexts["Kiểm thử Studio"].tap(); waitForReady(app)
        func grip(_ prefix: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
        }
        let audio = grip("audioTrack_"), overlay = grip("overlayTrack_")
        let audioStart = grip("trimAudioStart_"), audioEnd = grip("trimAudioEnd_")
        let overlayStart = grip("trimOverlayStart_"), overlayEnd = grip("trimOverlayEnd_")
        XCTAssertTrue(audioStart.waitForExistence(timeout: 10)); XCTAssertTrue(audioStart.isHittable)
        dragHandle(audioStart, points: 24); waitForReady(app)
        let source = audioStart.value as? String, offset = audio.value as? String
        XCTAssertNotEqual(source, "00:00.0"); XCTAssertNotEqual(offset, "00:01.0")
        XCTAssertEqual(audioEnd.value as? String, "00:04.0")
        dragHandle(audioEnd, points: -24); waitForReady(app)
        let soundEnd = audioEnd.value as? String
        XCTAssertNotEqual(soundEnd, "00:04.0"); XCTAssertEqual(audioStart.value as? String, source)
        XCTAssertEqual(audio.value as? String, offset)
        app.buttons["undo"].tap(); waitForReady(app)
        XCTAssertEqual(audioEnd.value as? String, "00:04.0"); XCTAssertEqual(audioStart.value as? String, source)
        app.buttons["redo"].tap(); waitForReady(app)
        dragHandle(overlayEnd, points: -16); waitForReady(app)
        let overlayOut = overlayEnd.value as? String
        XCTAssertNotEqual(overlayOut, "00:02.0"); XCTAssertEqual(overlay.value as? String, "00:02.0")
        dragHandle(overlayStart, points: 16); waitForReady(app)
        let overlayIn = overlayStart.value as? String, overlayOffset = overlay.value as? String
        XCTAssertNotEqual(overlayIn, "00:00.0"); XCTAssertNotEqual(overlayOffset, "00:02.0")
        XCTAssertEqual(overlayEnd.value as? String, overlayOut)
        let portrait = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); portrait.name = "Direct secondary trim portrait"; portrait.lifetime = .keepAlways; add(portrait)
        rotateAndSettle(app, landscape: true)
        XCTAssertTrue(audioStart.isHittable); XCTAssertTrue(audioEnd.isHittable)
        XCTAssertTrue(overlayStart.isHittable); XCTAssertTrue(overlayEnd.isHittable)
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); landscape.name = "Direct secondary trim landscape"; landscape.lifetime = .keepAlways; add(landscape)
        app.buttons["undo"].tap(); waitForReady(app)
        XCTAssertEqual(overlayStart.value as? String, "00:00.0"); XCTAssertEqual(overlayEnd.value as? String, overlayOut)
        app.buttons["redo"].tap(); waitForReady(app)
        app.terminate(); app.launchArguments = ["--uitesting"]; app.launch()
        XCTAssertTrue(app.staticTexts["Kiểm thử Studio"].waitForExistence(timeout: 20)); app.staticTexts["Kiểm thử Studio"].tap(); waitForReady(app)
        XCTAssertEqual(audioStart.value as? String, source); XCTAssertEqual(audioEnd.value as? String, soundEnd)
        XCTAssertEqual(audio.value as? String, offset)
        XCTAssertEqual(overlayStart.value as? String, overlayIn); XCTAssertEqual(overlayEnd.value as? String, overlayOut)
        XCTAssertEqual(overlay.value as? String, overlayOffset)
        audio.tap(); XCTAssertEqual(app.staticTexts["sourceStartTime"].label, source); app.buttons["Hủy"].tap()
    }

    func testPinchAcrossSecondaryRowsKeepsPlayheadAndSourceRanges() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "--uitesting-reset", "--uitesting-fixture", "--uitesting-multitrack"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Kiểm thử Studio"].waitForExistence(timeout: 30)); app.staticTexts["Kiểm thử Studio"].tap(); waitForReady(app)
        let timeline = app.collectionViews["centeredTimeline"]
        let audioStart = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'trimAudioStart_' ")).firstMatch
        let audioEnd = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'trimAudioEnd_' ")).firstMatch
        let sourceStart = audioStart.value as? String, sourceEnd = audioEnd.value as? String
        let time = app.staticTexts["playheadTime"].label
        let zoom = app.sliders["timelineZoom"]
        let originalZoom = zoom.value as? String
        timeline.pinch(withScale: 1.3, velocity: 1)
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value != %@", originalZoom ?? ""), object: zoom)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed, "Pinching over secondary rows must zoom the native timeline")
        XCTAssertEqual(app.staticTexts["playheadTime"].label, time)
        XCTAssertEqual(audioStart.value as? String, sourceStart); XCTAssertEqual(audioEnd.value as? String, sourceEnd)
        XCTAssertFalse(app.buttons["undo"].isEnabled, "A presentation-only zoom must not create an edit")
    }

    func dragHandle(_ handle: XCUIElement, points: CGFloat) {
        XCTAssertTrue(handle.isHittable, "The trim grip must be visible and reachable")
        let from = handle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: points, dy: 0)))
    }

    func waitForReady(_ app: XCUIApplication) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["playPause"])
        let result = XCTWaiter.wait(for: [ready], timeout: 20)
        if result != .completed {
            let state = app.staticTexts["playerDebug"]
            let status = app.staticTexts["statusMessage"]
            let detail = (state.exists ? state.label : "No player diagnostics") + " | " + (status.exists ? status.label : "No status message")
            let snapshot = XCTAttachment(string: app.debugDescription); snapshot.name = "Multi-track failure hierarchy"; snapshot.lifetime = .keepAlways; add(snapshot)
            print("MULTITRACK_FAILURE " + detail)
            XCTAssertEqual(result, .completed, detail)
        }
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
