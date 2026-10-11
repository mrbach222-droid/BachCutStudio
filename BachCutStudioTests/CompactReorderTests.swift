import XCTest
import UIKit
import AVFoundation
@testable import BachCutStudio

final class CompactReorderTests: XCTestCase {
    func project(count: Int = 6) -> StudioProject {
        var p = StudioProject()
        p.clips = (0..<count).map {
            VideoSegment(url: URL(fileURLWithPath: "/fixture\($0).mov"), start: 0, end: $0 == 0 ? 30 : 0.5)
        }
        return p
    }
    func testCompactSlotAndEdgeBounds() {
        XCTAssertEqual(TimelineReorderGeometry.index(at: 127, count: 6), 1)
        XCTAssertEqual(TimelineReorderGeometry.index(at: 215, count: 6), 2)
        XCTAssertEqual(TimelineReorderGeometry.index(at: -.greatestFiniteMagnitude, count: 6), 0)
        XCTAssertEqual(TimelineReorderGeometry.index(at: .greatestFiniteMagnitude, count: 6), 5)
        XCTAssertEqual(TimelineReorderGeometry.index(at: .nan, count: 0), 0)
        XCTAssertEqual(TimelineReorderGeometry.velocity(at: 0, viewport: 390), -240)
        XCTAssertEqual(TimelineReorderGeometry.velocity(at: 390, viewport: 390), 240)
        XCTAssertEqual(TimelineReorderGeometry.velocity(at: 195, viewport: 390), 0)
        XCTAssertEqual(TimelineReorderGeometry.velocity(at: .nan, viewport: 390), 0)
    }
    @MainActor func testInsertBetweenUnequalClipsOnlyCommitsOnRelease() {
        let p = project(count: 4)
        let view = TimelineSurface(frame: CGRect(x: 0, y: 0, width: 390, height: 140))
        view.layoutIfNeeded()
        view.apply(project: p, selected: p.clips[3].id, thumbnails: [:], zoom: 24, playhead: 3, enabled: true)
        var moves: [(UUID, Int)] = []; var scrubs = 0
        view.onMove = { moves.append(($0, $1)) }; view.onScrub = { _ in scrubs += 1 }
        XCTAssertTrue(view.beginReorder(at: 3, point: CGPoint(x: 195, y: 58)))
        defer { view.cancelInteraction() }
        for index in 0..<4 {
            XCTAssertEqual(view.layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))!.size.width, 80)
        }
        let targetX = 128 - view.collection.contentOffset.x
        // A finger dropping below the main row still uses the same horizontal insertion slot.
        UIView.performWithoutAnimation { view.updateReorder(at: CGPoint(x: targetX, y: 180)) }
        let gap = view.subviews.first { $0.accessibilityIdentifier == "reorderInsertion" }!
        XCTAssertEqual(gap.accessibilityValue, "2/4"); XCTAssertFalse(gap.isHidden)
        XCTAssertTrue(moves.isEmpty); XCTAssertEqual(scrubs, 0)
        view.finishReorder(commit: true)
        XCTAssertEqual(moves.count, 1); XCTAssertEqual(moves.first?.0, p.clips[3].id); XCTAssertEqual(moves.first?.1, 1)
        XCTAssertTrue(gap.isHidden); XCTAssertTrue(view.collection.isScrollEnabled)
        XCTAssertEqual(view.collection.contentOffset.x + view.collection.contentInset.left, 72, accuracy: 0.01)
        XCTAssertEqual(view.layout.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))!.size.width, 720)
        view.finishReorder(commit: true); XCTAssertEqual(moves.count, 1)
    }
    @MainActor func testStationaryEdgeHoldScrollsBothWaysAndStopsAfterCancel() {
        let p = project(count: 20)
        let view = TimelineSurface(frame: CGRect(x: 0, y: 0, width: 390, height: 140)); view.layoutIfNeeded()
        view.apply(project: p, selected: p.clips[0].id, thumbnails: [:], zoom: 80, playhead: 2, enabled: true)
        var moves = 0; var scrubs = 0
        view.onMove = { _, _ in moves += 1 }; view.onScrub = { _ in scrubs += 1 }
        XCTAssertTrue(view.beginReorder(at: 0, point: CGPoint(x: 195, y: 58)))
        defer { view.cancelInteraction() }
        let start = view.collection.contentOffset.x
        UIView.performWithoutAnimation {
            view.updateReorder(at: CGPoint(x: 389, y: 170))
            for _ in 0..<120 { view.advanceReorder(by: 1.0 / 60) }
        }
        XCTAssertGreaterThan(view.collection.contentOffset.x, start + 400)
        let right = view.collection.contentOffset.x
        UIView.performWithoutAnimation {
            view.updateReorder(at: CGPoint(x: 1, y: 170))
            for _ in 0..<120 { view.advanceReorder(by: 1.0 / 60) }
        }
        XCTAssertLessThan(view.collection.contentOffset.x, right - 400)
        XCTAssertEqual(moves, 0); XCTAssertEqual(scrubs, 0)
        view.finishReorder(commit: false)
        let restored = view.collection.contentOffset.x
        view.advanceReorder(by: 1)
        XCTAssertEqual(view.collection.contentOffset.x, restored)
        XCTAssertEqual(restored + view.collection.contentInset.left, 160, accuracy: 0.01)
    }
    @MainActor func testRotationZoomAndDisabledEditorDiscardPendingOrder() {
        let p = project(count: 4)
        let view = TimelineSurface(frame: CGRect(x: 0, y: 0, width: 390, height: 140)); view.layoutIfNeeded()
        var commits = 0; view.onMove = { _, _ in commits += 1 }
        for reason in 0..<4 {
            view.apply(project: p, selected: p.clips[0].id, thumbnails: [:], zoom: 24, playhead: 2, enabled: true)
            XCTAssertTrue(view.beginReorder(at: 0, point: CGPoint(x: 195, y: 58)))
            UIView.performWithoutAnimation { view.updateReorder(at: CGPoint(x: 370, y: 58)) }
            if reason == 0 { view.frame.size.width = 700; view.setNeedsLayout(); view.layoutIfNeeded() }
            else {
                var next = p
                if reason == 3 { next.id = UUID() }
                view.apply(project: next, selected: p.clips[0].id, thumbnails: [:], zoom: reason == 1 ? 48 : 24, playhead: 2, enabled: reason != 2)
            }
            view.finishReorder(commit: true)
            XCTAssertEqual(commits, 0); XCTAssertTrue(view.collection.isScrollEnabled)
            XCTAssertTrue(view.subviews.first { $0.accessibilityIdentifier == "reorderInsertion" }!.isHidden)
        }
    }
    @MainActor func testNativeHeldInsertionScreenshots() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var p = StudioProject(); var thumbnails: [UUID: [UIImage]] = [:]
        for (index, color) in [UIColor.red, .green, .blue, .orange].enumerated() {
            let url = root.appendingPathComponent("\(index).mov")
            try await TestMedia.video(to: url, color: color, duration: 1)
            let clip = VideoSegment(url: url, start: 0, end: 1); p.clips.append(clip)
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            thumbnails[clip.id] = [UIImage(cgImage: try generator.copyCGImage(at: .zero, actualTime: nil))]
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 160))
        let view = TimelineSurface(frame: window.bounds); window.addSubview(view); window.isHidden = false
        defer { view.cancelInteraction(); window.isHidden = true }
        view.layoutIfNeeded()
        view.apply(project: p, selected: p.clips[3].id, thumbnails: thumbnails, zoom: 80, playhead: 2.5, enabled: true)
        for width in [CGFloat(390), CGFloat(700)] {
            window.frame.size.width = width; view.frame = window.bounds; view.setNeedsLayout(); view.layoutIfNeeded()
            XCTAssertTrue(view.beginReorder(at: 3, point: CGPoint(x: width / 2, y: 58)))
            UIView.performWithoutAnimation { view.updateReorder(at: CGPoint(x: 216 - view.collection.contentOffset.x, y: 130)) }
            view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: view.bounds).image { view.layer.render(in: $0.cgContext) }
            let shot = XCTAttachment(image: image); shot.name = "Native held insertion \(Int(width))pt"; shot.lifetime = .keepAlways; add(shot)
            XCTAssertEqual(view.subviews.first { $0.accessibilityIdentifier == "reorderInsertion" }!.accessibilityValue, "3/4")
            view.finishReorder(commit: false)
        }
    }
    @MainActor func testReleasedInsertionExportsCorrectSourceOrderAndPersistsHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ProjectStore(root: root); try store.prepare()
        defer { try? FileManager.default.removeItem(at: root) }
        var p = StudioProject()
        for (index, color) in [UIColor.red, .green, .blue].enumerated() {
            let url = store.mediaDirectory.appendingPathComponent("\(index).mov")
            try await TestMedia.video(to: url, color: color, duration: 2)
            p.clips.append(VideoSegment(url: url, start: index == 1 ? 0 : 0.25,
                                        end: index == 1 ? 2 : 1.25, sourceDuration: 2, speed: index == 0 ? 2 : 1))
        }
        let model = EditorModel(project: p, store: store); defer { model.close() }
        model.seek(1.25); await model.start()
        let view = TimelineSurface(frame: CGRect(x: 0, y: 0, width: 390, height: 140)); view.layoutIfNeeded()
        view.apply(project: p, selected: p.clips[2].id, thumbnails: [:], zoom: 80, playhead: 1.25, enabled: true)
        view.onBeginMove = { model.pause(); model.selected = $0 }; view.onMove = model.moveClip
        XCTAssertTrue(view.beginReorder(at: 2, point: CGPoint(x: 195, y: 58)))
        defer { view.cancelInteraction() }
        UIView.performWithoutAnimation {
            view.updateReorder(at: CGPoint(x: 107, y: 170))
            view.updateReorder(at: CGPoint(x: 195, y: 170))
            view.updateReorder(at: CGPoint(x: 107, y: 170))
        }
        XCTAssertEqual(model.project, p); XCTAssertTrue(model.undoStack.isEmpty)
        view.finishReorder(commit: true)
        let expected = [p.clips[0], p.clips[2], p.clips[1]]
        XCTAssertEqual(model.clips, expected); XCTAssertEqual(model.undoStack.count, 1)
        XCTAssertEqual(model.playhead, 1.25, accuracy: 0.001)
        model.undo(); XCTAssertEqual(model.clips, p.clips)
        model.redo(); XCTAssertEqual(model.clips, expected)
        XCTAssertTrue(model.saveProject()); XCTAssertEqual(try store.list().first?.clips, expected)
        let composition = try await MediaComposer.build(model.project)
        let output = root.appendingPathComponent("reordered.mp4")
        try await MediaComposer.export(composition, to: output)
        let asset = AVURLAsset(url: output)
        let length = try await asset.load(.duration)
        XCTAssertEqual(length.seconds, 3.5, accuracy: 0.08)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        for (time, channel) in [(0.2, 0), (0.8, 2), (2.0, 1)] {
            let (image, _) = try await generator.image(at: MediaComposer.time(time))
            var rgba = [UInt8](repeating: 0, count: 4)
            rgba.withUnsafeMutableBytes { bytes in
                let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            XCTAssertGreaterThan(rgba[channel], 180, "Exported frames must follow the released insertion order")
            for other in 0..<3 where other != channel { XCTAssertLessThan(rgba[other], 80) }
        }
    }
}
