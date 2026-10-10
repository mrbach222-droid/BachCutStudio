import XCTest
import AVFoundation
import UIKit
@testable import BachCutStudio

final class StudioTests: XCTestCase {
    func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func testSplitUsesSourceSpeedAndPreservesDuration() {
        var p = StudioProject()
        let clip = VideoSegment(url: URL(fileURLWithPath: "/source.mov"), start: 1, end: 9, sourceDuration: 10, speed: 2, volume: 0.25)
        p.clips = [clip]
        let right = p.split(id: clip.id, at: 1.5)
        XCTAssertNotNil(right); XCTAssertEqual(p.clips.count, 2)
        XCTAssertEqual(p.clips[0].end, 4); XCTAssertEqual(p.clips[1].start, 4)
        XCTAssertEqual(p.clips[1].speed, 2); XCTAssertEqual(p.clips[1].volume, 0.25)
        XCTAssertEqual(p.duration, 4, accuracy: 0.001)
        XCTAssertNil(p.split(id: clip.id, at: 0))
        XCTAssertNil(p.split(id: right!, at: 4))
    }
    func testDuplicateKeepsIndependentIdentityAndEdits() {
        var p = StudioProject(); p.clips = [VideoSegment(url: URL(fileURLWithPath: "/a.mov"), start: 0, end: 2, speed: 0.5, volume: 0)]
        let id = p.duplicate(id: p.clips[0].id)
        XCTAssertNotEqual(id, p.clips[0].id); XCTAssertEqual(p.duration, 8)
        p.clips[1].start = 1; XCTAssertEqual(p.clips[0].start, 0)
    }
    func testNormalizationRejectsInvalidNumbersAndBounds() {
        var clip = VideoSegment(url: URL(fileURLWithPath: "/a.mov"), start: -3, end: 900, sourceDuration: 4, speed: .nan, volume: 9)
        clip.normalize(); XCTAssertEqual(clip.start, 0); XCTAssertEqual(clip.end, 4); XCTAssertEqual(clip.speed, 1); XCTAssertEqual(clip.volume, 1)
    }
    func testStoreSurvivesContainerRelocationAndLegacyMigration() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root); try store.prepare()
        var p = StudioProject(); p.name = "Bách – bản dựng"
        let url = store.mediaDirectory.appendingPathComponent("a.mov")
        try Data([1, 2]).write(to: url)
        p.clips = [VideoSegment(url: url, start: 0.5, end: 4, sourceDuration: 5, speed: 2)]
        p.audio = [AudioSegment(url: url, offset: 1, sourceDuration: 5)]
        p.overlays = [OverlaySegment(clip: p.clips[0], offset: 0.5)]; p.ratio = .square
        try store.save(p)
        let newRoot = root.appendingPathComponent("relocated")
        try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: store.mediaDirectory, to: newRoot.appendingPathComponent("Media"))
        try FileManager.default.copyItem(at: store.projectsDirectory, to: newRoot.appendingPathComponent("Projects"))
        let restored = try ProjectStore(root: newRoot).list()[0]
        XCTAssertEqual(restored.name, p.name); XCTAssertEqual(restored.ratio, .square)
        XCTAssertEqual(restored.clips[0].speed, 2); XCTAssertEqual(restored.audio[0].offset, 1)
        XCTAssertEqual(restored.clips[0].url, newRoot.appendingPathComponent("Media/a.mov"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: restored.overlays[0].clip.url.path))
        let legacy = "{\"name\":\"Cũ\",\"clips\":[{\"id\":\"\(UUID().uuidString)\",\"url\":\"file:///old/container/Media/a.mov\",\"start\":0,\"end\":2}]}"
        try Data(legacy.utf8).write(to: root.appendingPathComponent("bachcut-project.json"))
        try store.migrateLegacy(); try store.migrateLegacy()
        XCTAssertEqual(try store.list().count, 2)
        XCTAssertTrue(try store.list().contains { $0.name == "Cũ" })
    }
    func testTransformFitsRotatedVideoAndEvenCanvas() {
        let transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 90, ty: 0)
        let canvas = MediaComposer.canvasSize(ratio: .original, natural: CGSize(width: 160, height: 90), transform: transform)
        XCTAssertEqual(canvas, CGSize(width: 90, height: 160))
        let fitted = MediaComposer.fittedTransform(size: CGSize(width: 160, height: 90), transform: transform, canvas: CGSize(width: 200, height: 200))
        let rect = CGRect(x: 0, y: 0, width: 160, height: 90).applying(fitted)
        XCTAssertEqual(rect.midX, 100, accuracy: 0.001); XCTAssertEqual(rect.midY, 100, accuracy: 0.001)
        XCTAssertLessThanOrEqual(rect.width, 200); XCTAssertLessThanOrEqual(rect.height, 200)
    }
    func testRealExportMixedOrientationSpeedOverlayAndAudio() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let red = root.appendingPathComponent("red.mov"), blue = root.appendingPathComponent("blue.mov"), green = root.appendingPathComponent("green.mov"), sound = root.appendingPathComponent("tone.caf")
        try await TestMedia.video(to: red, color: .red, duration: 2)
        try await TestMedia.video(to: blue, color: .blue, duration: 2, rotated: true)
        try await TestMedia.video(to: green, color: .green, duration: 1)
        try TestMedia.audio(to: sound, duration: 4)
        var p = StudioProject(); p.ratio = .square
        p.clips = [VideoSegment(url: red, start: 0.5, end: 1.5), VideoSegment(url: blue, start: 0, end: 2, speed: 2)]
        p.audio = [AudioSegment(url: sound, offset: 0.25, sourceDuration: 4)]
        p.overlays = [OverlaySegment(clip: VideoSegment(url: green, start: 0, end: 1), offset: 0.5)]
        let rendered = try await MediaComposer.build(p)
        XCTAssertEqual(rendered.composition.duration.seconds, 2, accuracy: 0.04)
        XCTAssertEqual(rendered.video.renderSize, CGSize(width: 160, height: 160))
        XCTAssertEqual(rendered.composition.tracks(withMediaType: .video).count, 2)
        XCTAssertEqual(rendered.composition.tracks(withMediaType: .audio).count, 1)
        let output = root.appendingPathComponent("export.mp4")
        try await MediaComposer.export(rendered, to: output)
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.08)
        let exportedAudioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(exportedAudioTracks.count, 1)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let exportedSize = try await track.load(.naturalSize)
        XCTAssertEqual(exportedSize, CGSize(width: 160, height: 160))
        let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let (first, _) = try await generator.image(at: MediaComposer.time(0.2))
        let (second, _) = try await generator.image(at: MediaComposer.time(1.7))
        let (overlay, _) = try await generator.image(at: MediaComposer.time(0.8))
        let r = pixel(first, x: 80, y: 80), b = pixel(second, x: 80, y: 80), g = pixel(overlay, x: 120, y: 36)
        XCTAssertGreaterThan(r[0], 180); XCTAssertLessThan(r[2], 70)
        XCTAssertGreaterThan(b[2], 180); XCTAssertLessThan(b[0], 70)
        XCTAssertGreaterThan(g[1], 160); XCTAssertLessThan(g[0], 80)
        let reader = try AVAssetReader(asset: asset)
        let audioTrack = try await asset.loadTracks(withMediaType: .audio)[0]
        let outputAudio = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
        reader.add(outputAudio); XCTAssertTrue(reader.startReading())
        var bytes = Data()
        while let sample = outputAudio.copyNextSampleBuffer() {
            if let block = CMSampleBufferGetDataBuffer(sample) {
                let length = CMBlockBufferGetDataLength(block); var chunk = Data(count: length)
                chunk.withUnsafeMutableBytes { ptr in _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: ptr.baseAddress!) }
                bytes.append(chunk)
            }
        }
        XCTAssertEqual(reader.status, .completed); XCTAssertGreaterThan(bytes.count, 1000)
        let peak = bytes.withUnsafeBytes { ptr -> Int in ptr.bindMemory(to: Int16.self).map { abs(Int($0)) }.max() ?? 0 }
        XCTAssertGreaterThan(peak, 500, "Exported audio must contain a real waveform")
    }
    func testSourceAudioFollowsSpeedAndMute() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("source.mov"), sound = root.appendingPathComponent("sound.caf")
        try await TestMedia.video(to: video, color: .red, duration: 2)
        try TestMedia.audio(to: sound, duration: 2)
        var seed = StudioProject(); seed.clips = [VideoSegment(url: video, start: 0, end: 2)]
        seed.audio = [AudioSegment(url: sound, sourceDuration: 2, volume: 1)]
        let source = root.appendingPathComponent("with-audio.mp4")
        let seedRendered = try await MediaComposer.build(seed)
        try await MediaComposer.export(seedRendered, to: source)
        var edited = StudioProject()
        edited.clips = [VideoSegment(url: source, start: 0, end: 2, speed: 2, volume: 1),
                        VideoSegment(url: source, start: 0, end: 2, speed: 0.5, volume: 0)]
        let output = root.appendingPathComponent("speed-mute.mp4")
        let editedRendered = try await MediaComposer.build(edited)
        try await MediaComposer.export(editedRendered, to: output)
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 5, accuracy: 0.08)
        let audible = try await audioPeak(asset: asset, start: 0.2, length: 0.5)
        let muted = try await audioPeak(asset: asset, start: 1.5, length: 1)
        XCTAssertGreaterThan(audible, 500)
        XCTAssertLessThan(muted, 100, "Muted source audio must stay muted after speed changes")
    }
    func audioPeak(asset: AVAsset, start: Double, length: Double) async throws -> Int {
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: MediaComposer.time(start), duration: MediaComposer.time(length))
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false])
        reader.add(output); XCTAssertTrue(reader.startReading())
        var peak = 0
        while let sample = output.copyNextSampleBuffer() {
            if let block = CMSampleBufferGetDataBuffer(sample) {
                let count = CMBlockBufferGetDataLength(block); var bytes = Data(count: count)
                bytes.withUnsafeMutableBytes { pointer in _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: pointer.baseAddress!) }
                peak = max(peak, bytes.withUnsafeBytes { $0.bindMemory(to: Int16.self).map { abs(Int($0)) }.max() ?? 0 })
            }
        }
        XCTAssertEqual(reader.status, .completed)
        return peak
    }
    func pixel(_ image: CGImage, x: Int, y: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { pointer in
            let ctx = CGContext(data: pointer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        let index = (y * image.width + x) * 4
        return Array(bytes[index..<index + 4])
    }
    @MainActor func testModelImportEditingUndoPlaybackPersistenceAndExport() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input.mov")
        try await TestMedia.video(to: source, color: .red, duration: 2)
        let model = EditorModel(store: ProjectStore(root: root)); defer { model.close() }
        await model.add(url: source)
        try await waitForPreview(model)
        XCTAssertEqual(model.clips.count, 1); XCTAssertNotNil(model.player)
        let id = model.clips[0].id
        model.trim(id, start: 0.5, end: 99); XCTAssertEqual(model.clips[0].end, 2, accuracy: 0.03)
        model.seek(1); model.splitSelected(); XCTAssertEqual(model.clips.count, 2)
        let duration = model.duration
        model.duplicateSelected(); XCTAssertEqual(model.clips.count, 3)
        model.undo(); XCTAssertEqual(model.clips.count, 2); XCTAssertEqual(model.duration, duration)
        model.redo(); XCTAssertEqual(model.clips.count, 3)
        model.removeSelected(); XCTAssertEqual(model.clips.count, 2)
        try await waitForPreview(model)
        model.seek(0); model.togglePlayback()
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertGreaterThan(model.playhead, 0.1); model.pause()
        let position = model.playhead
        model.setVolume(0.5); try await waitForPreview(model)
        XCTAssertEqual(model.playhead, position, accuracy: 0.12)
        let restored = try model.store.list()[0]
        XCTAssertEqual(restored.clips, model.clips)
        await model.export()
        let exported = try XCTUnwrap(model.exportedURL, model.progress)
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.path))
        model.seek(0); model.togglePlayback()
        try await Task.sleep(nanoseconds: 250_000_000)
        model.setVolume(0.25); model.pause()
        try await waitForPreview(model)
        XCTAssertFalse(model.playing, "Pause during preview rebuild must not auto-resume")
        model.close()
        let reopened = EditorModel(project: restored, store: model.store); defer { reopened.close() }
        await reopened.start(); XCTAssertNotNil(reopened.player)
    }
    @MainActor func waitForPreview(_ model: EditorModel) async throws {
        // The rebuild task starts on the next main actor turn.
        try await Task.sleep(nanoseconds: 50_000_000)
        for _ in 0..<200 {
            if !model.rendering && model.playerReady { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Preview did not finish: " + model.progress)
    }
    @MainActor func testThumbnailRefreshesAfterTrimmingSourceStart() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let red = root.appendingPathComponent("red.mov"), blue = root.appendingPathComponent("blue.mov")
        try await TestMedia.video(to: red, color: .red, duration: 1)
        try await TestMedia.video(to: blue, color: .blue, duration: 1)
        var seed = StudioProject(); seed.clips = [VideoSegment(url: red, start: 0, end: 1), VideoSegment(url: blue, start: 0, end: 1)]
        let source = root.appendingPathComponent("combined.mp4")
        let rendered = try await MediaComposer.build(seed)
        try await MediaComposer.export(rendered, to: source)
        let model = EditorModel(store: ProjectStore(root: root)); defer { model.close() }
        await model.add(url: source); try await waitForPreview(model); await model.loadThumbnails()
        let id = model.clips[0].id
        let first = try XCTUnwrap(model.thumbnails[id]?.cgImage)
        XCTAssertGreaterThan(pixel(first, x: first.width / 2, y: first.height / 2)[0], 180)
        model.trim(id, start: 1.2)
        try await waitForPreview(model); await model.loadThumbnails()
        let second = try XCTUnwrap(model.thumbnails[id]?.cgImage)
        XCTAssertGreaterThan(pixel(second, x: second.width / 2, y: second.height / 2)[2], 180)
    }
    @MainActor func testInvalidImportDoesNotPolluteProjectOrMedia() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root); try store.prepare()
        let url = root.appendingPathComponent("bad.mov"); try Data("not a video".utf8).write(to: url)
        let model = EditorModel(store: store); defer { model.close() }
        await model.add(url: url)
        XCTAssertTrue(model.clips.isEmpty); XCTAssertFalse(model.busy)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.mediaDirectory.path).count, 0)
    }

    @MainActor func testRawImportedAndSavedPlaybackOnNativeLayer() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("native.mov")
        try await TestMedia.video(to: source, color: .red, duration: 8)
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow })
        let surface = PlayerSurface(frame: CGRect(x: 20, y: 140, width: 320, height: 180))
        surface.videoLayer.videoGravity = .resizeAspect
        window.addSubview(surface); window.layoutIfNeeded()
        defer { surface.videoLayer.player = nil; surface.removeFromSuperview() }
        let raw = AVPlayer(url: source); raw.automaticallyWaitsToMinimizeStalling = false
        surface.videoLayer.player = raw
        for _ in 0..<200 {
            if raw.currentItem?.status == .readyToPlay { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        raw.playImmediately(atRate: 1)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        print("RAW_LAYER time=\(raw.currentTime().seconds) rate=\(raw.rate) ready=\(raw.currentItem?.status.rawValue ?? -1) control=\(raw.timeControlStatus.rawValue) frame=\(surface.videoLayer.isReadyForDisplay)")
        XCTAssertGreaterThan(raw.currentTime().seconds, 0.1)
        XCTAssertTrue(surface.videoLayer.isReadyForDisplay)
        raw.pause(); surface.videoLayer.player = nil
        var seed = StudioProject(); seed.clips = [VideoSegment(url: source, start: 0, end: 8)]
        let rendered = try await MediaComposer.build(seed)
        print("VIDEO_VALID=\(rendered.video.isValid(for: rendered.composition, timeRange: CMTimeRange(start: .zero, duration: rendered.composition.duration), validationDelegate: nil)) tracks=\(rendered.composition.tracks.map { $0.trackID }) timing=\(rendered.video.sourceTrackIDForFrameTiming)")
        for mode in ["COMPOSITION_ONLY", "COMPOSITION_VIDEO", "COMPOSITION_AUTO", "EXPORTED_FILE"] {
            let item: AVPlayerItem
            if mode == "EXPORTED_FILE" {
                let output = root.appendingPathComponent("native-export.mp4")
                try await MediaComposer.export(rendered, to: output)
                item = AVPlayerItem(url: output)
            } else {
                item = AVPlayerItem(asset: rendered.composition)
                if mode == "COMPOSITION_VIDEO" { item.videoComposition = rendered.video }
                if mode == "COMPOSITION_AUTO" { item.videoComposition = AVMutableVideoComposition(propertiesOf: rendered.composition) }
            }
            let candidate = AVPlayer(playerItem: item); candidate.automaticallyWaitsToMinimizeStalling = false
            surface.videoLayer.player = candidate
            for _ in 0..<200 {
                if item.status == .readyToPlay { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            candidate.playImmediately(atRate: 1)
            try await Task.sleep(nanoseconds: 1_000_000_000)
            print("\(mode) time=\(candidate.currentTime().seconds) rate=\(candidate.rate) status=\(item.status.rawValue) frame=\(surface.videoLayer.isReadyForDisplay) error=\(String(describing: item.error))")
            XCTAssertGreaterThan(candidate.currentTime().seconds, 0.1, mode)
            XCTAssertTrue(surface.videoLayer.isReadyForDisplay, mode)
            candidate.pause(); surface.videoLayer.player = nil
        }
        let model = EditorModel(store: ProjectStore(root: root)); defer { model.close() }
        await model.add(url: source); try await waitForPreview(model)
        surface.videoLayer.player = model.player
        print("BEFORE_TOGGLE playing=\(model.playing) " + model.debugInfo)
        model.togglePlayback(); try await Task.sleep(nanoseconds: 1_000_000_000)
        print("IMPORTED_LAYER " + model.debugInfo + " frame=\(surface.videoLayer.isReadyForDisplay)")
        XCTAssertGreaterThan(model.player?.currentTime().seconds ?? 0, 0.1)
        XCTAssertGreaterThan(model.playhead, 0.1)
        XCTAssertTrue(surface.videoLayer.isReadyForDisplay)
        model.close(); surface.videoLayer.player = nil
        let restored = try model.store.list()[0]
        let reopened = EditorModel(project: restored, store: model.store); defer { reopened.close() }
        await reopened.start(); try await waitForPreview(reopened)
        surface.videoLayer.player = reopened.player
        reopened.togglePlayback(); try await Task.sleep(nanoseconds: 1_000_000_000)
        print("SAVED_LAYER " + reopened.debugInfo + " frame=\(surface.videoLayer.isReadyForDisplay)")
        XCTAssertGreaterThan(reopened.player?.currentTime().seconds ?? 0, 0.1)
        XCTAssertGreaterThan(reopened.playhead, 0.1)
        XCTAssertTrue(surface.videoLayer.isReadyForDisplay)
    }
}
