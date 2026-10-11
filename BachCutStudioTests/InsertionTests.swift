import XCTest
import AVFoundation
import UIKit
@testable import BachCutStudio

final class InsertionTests: XCTestCase {
    let source = URL(fileURLWithPath: "/source.mov")
    func testInsertionSplitsSourceAtSpeedAndKeepsSecondaryOffsets() {
        var p = StudioProject()
        let original = VideoSegment(url: source, start: 2, end: 10, sourceDuration: 12, speed: 2, volume: 0.3)
        let next = VideoSegment(url: source, start: 0, end: 1)
        let inserted = VideoSegment(url: URL(fileURLWithPath: "/insert.mov"), start: 0, end: 2)
        p.clips = [original, next]
        p.audio = [AudioSegment(url: source, offset: 2, sourceDuration: 10, sourceStart: 3)]
        p.overlays = [OverlaySegment(clip: next, offset: 3)]
        let sounds = p.audio, overlays = p.overlays
        XCTAssertEqual(p.insert([inserted], at: 1.5), 1.5)
        XCTAssertEqual(p.clips.map(\.url), [source, inserted.url, source, source])
        XCTAssertEqual(p.clips[0].id, original.id); XCTAssertNotEqual(p.clips[2].id, original.id)
        XCTAssertEqual(p.clips[0].end, 5); XCTAssertEqual(p.clips[2].start, 5)
        XCTAssertEqual(p.clips[2].end, 10); XCTAssertEqual(p.clips[2].speed, 2)
        XCTAssertEqual(p.clips[2].volume, 0.3); XCTAssertEqual(p.clips[2].sourceDuration, 12)
        XCTAssertEqual(p.duration, 7); XCTAssertEqual(p.audio, sounds); XCTAssertEqual(p.overlays, overlays)
        XCTAssertEqual(Set(p.clips.map(\.id)).count, p.clips.count)
    }
    func testInsertionSnapsBoundsAndNeverCreatesTinyFragments() {
        let a = VideoSegment(url: source, start: 0, end: 2)
        let b = VideoSegment(url: source, start: 0, end: 0.08)
        let incoming = VideoSegment(url: source, start: 0, end: 1)
        for (time, expected, index) in [(-1.0, 0.0, 0), (0.04, 0.0, 0), (1.98, 2.0, 1), (2.0, 2.0, 1), (2.04, 2.0, 1), (9.0, 2.08, 2), (Double.nan, 2.08, 2)] {
            var p = StudioProject(); p.clips = [a, b]
            XCTAssertEqual(p.insert([incoming], at: time), expected, accuracy: 0.0001)
            XCTAssertEqual(p.clips.count, 3); XCTAssertEqual(p.clips[index].id, incoming.id)
            XCTAssertEqual(p.duration, 3.08, accuracy: 0.0001)
        }
        var empty = StudioProject(); XCTAssertEqual(empty.insert([incoming], at: 12), 0)
        XCTAssertEqual(empty.clips, [incoming])
    }
    @MainActor func testBatchImportInsertionHistoryStorageAndExportFrames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root); try store.prepare()
        let red = store.mediaDirectory.appendingPathComponent("red.mov")
        let blue = root.appendingPathComponent("blue.mov"), green = root.appendingPathComponent("green.mov")
        try await TestMedia.video(to: red, color: .red, duration: 10)
        try await TestMedia.video(to: blue, color: .blue, duration: 2)
        try await TestMedia.video(to: green, color: .green, duration: 2)
        var p = StudioProject(); p.clips = [VideoSegment(url: red, start: 2, end: 10, sourceDuration: 10, speed: 2, volume: 0.25)]
        let model = EditorModel(project: p, store: store); defer { model.close() }
        model.playhead = 2
        await model.add(urls: [blue, green], insertionTime: 2)
        XCTAssertEqual(model.clips.count, 4); XCTAssertEqual(model.duration, 8, accuracy: 0.001)
        XCTAssertEqual(model.clips[0].end, 6); XCTAssertEqual(model.clips[3].start, 6)
        XCTAssertEqual(model.selected, model.clips[1].id); XCTAssertEqual(model.playhead, 2)
        XCTAssertEqual(model.undoStack.count, 1); XCTAssertTrue(model.redoStack.isEmpty)
        let saved = model.project
        XCTAssertEqual(try store.list().first, saved)
        model.undo(); XCTAssertEqual(model.clips, p.clips); XCTAssertTrue(model.undoStack.isEmpty)
        model.redo(); XCTAssertEqual(model.clips, saved.clips)
        model.close()
        let rendered = try await MediaComposer.build(saved)
        let output = root.appendingPathComponent("insertion.mp4")
        try await MediaComposer.export(rendered, to: output)
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 8, accuracy: 0.08)
        let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        for (time, channel) in [(1.0, 0), (3.0, 2), (5.0, 1), (7.0, 0)] {
            let (image, _) = try await generator.image(at: MediaComposer.time(time))
            var bytes = [UInt8](repeating: 0, count: 4)
            bytes.withUnsafeMutableBytes { pointer in
                let context = CGContext(data: pointer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            XCTAssertGreaterThan(bytes[channel], 180, "Inserted source order must reach the actual exported frames")
            XCTAssertLessThan(bytes[(channel + 1) % 3], 70)
        }
    }
    @MainActor func testFailedBatchImportLeavesProjectHistoryAndMediaUntouched() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root); try store.prepare()
        let source = root.appendingPathComponent("valid.mov")
        try await TestMedia.video(to: source, color: .blue, duration: 1)
        let model = EditorModel(store: store); defer { model.close() }
        let prior = model.project
        await model.add(urls: [source, root.appendingPathComponent("missing.mov")], insertionTime: 0)
        XCTAssertEqual(model.project, prior); XCTAssertTrue(model.undoStack.isEmpty)
        XCTAssertTrue(model.redoStack.isEmpty); XCTAssertFalse(model.busy)
        XCTAssertTrue(model.progress.hasPrefix("Không nhập được:"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: store.mediaDirectory.path).isEmpty)
        XCTAssertTrue(try store.list().isEmpty)
    }
    @MainActor func testDefaultBatchImportStillAppendsAndHasOneUndo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root); try store.prepare()
        let source = root.appendingPathComponent("incoming.mov")
        try await TestMedia.video(to: source, color: .green, duration: 1)
        var p = StudioProject(); p.clips = [VideoSegment(url: source, start: 0, end: 1)]
        let model = EditorModel(project: p, store: store); defer { model.close() }
        model.playhead = 0.5
        await model.add(urls: [source, source])
        XCTAssertEqual(model.clips.count, 3); XCTAssertEqual(model.clips[0], p.clips[0])
        XCTAssertEqual(model.duration, 3, accuracy: 0.05); XCTAssertEqual(model.playhead, 0.5)
        XCTAssertEqual(model.undoStack.count, 1)
        model.undo(); XCTAssertEqual(model.clips, p.clips)
    }
}
