import XCTest
import AVFoundation
import UIKit
import ImageIO
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
        let initialFrames = try XCTUnwrap(model.thumbnails[id])
        XCTAssertEqual(initialFrames.count, 2)
        let first = try XCTUnwrap(initialFrames.first?.cgImage)
        XCTAssertGreaterThan(pixel(first, x: first.width / 2, y: first.height / 2)[0], 180)
        let last = try XCTUnwrap(initialFrames.last?.cgImage)
        XCTAssertGreaterThan(pixel(last, x: last.width / 2, y: last.height / 2)[2], 180)
        model.trim(id, start: 1.2)
        try await waitForPreview(model); await model.loadThumbnails()
        let second = try XCTUnwrap(model.thumbnails[id]?.first?.cgImage)
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
        let valid = try await rendered.video.isValid(for: rendered.composition, timeRange: CMTimeRange(start: .zero, duration: rendered.composition.duration), validationDelegate: nil)
        XCTAssertTrue(valid)
        XCTAssertFalse(rendered.needsVideoComposition)
        for forceFile in [false, true] {
            // Exercise the fast path and the composed-file path through the application preview API.
            let preview = try await MediaComposer.previewSource(rendered, directory: root.appendingPathComponent("Preview"), useFile: forceFile ? true : nil)
            defer { if let url = preview.temporaryURL { try? FileManager.default.removeItem(at: url) } }
            let candidate = AVPlayer(playerItem: preview.item); candidate.automaticallyWaitsToMinimizeStalling = false
            surface.videoLayer.player = candidate
            for _ in 0..<200 {
                if preview.item.status == .readyToPlay { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            candidate.playImmediately(atRate: 1)
            try await Task.sleep(nanoseconds: 1_000_000_000)
            print("PREVIEW_FILE=\(preview.temporaryURL != nil) time=\(candidate.currentTime().seconds) frame=\(surface.videoLayer.isReadyForDisplay)")
            XCTAssertGreaterThan(candidate.currentTime().seconds, 0.1)
            XCTAssertTrue(surface.videoLayer.isReadyForDisplay)
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
        model.pause(); model.setRatio(.square); try await waitForPreview(model)
        surface.videoLayer.player = model.player
        XCTAssertTrue(model.player?.currentItem?.asset is AVURLAsset, "Composed preview must use the rendered frame path")
        model.seek(0); model.togglePlayback(); try await Task.sleep(nanoseconds: 1_000_000_000)
        print("COMPOSED_MODEL " + model.debugInfo + " frame=\(surface.videoLayer.isReadyForDisplay)")
        XCTAssertGreaterThan(model.playhead, 0.1); XCTAssertTrue(surface.videoLayer.isReadyForDisplay)
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
    func testHEVCCodecSelectionAndPlayableExport() async throws {
        XCTAssertEqual(ExportOptions().codec, .h264, "H.264 stays the default for compatibility")
        XCTAssertEqual(VideoCodec.hevc.avCodec, .hevc)
        XCTAssertThrowsError(try ExportOptions(format: .gif, codec: .hevc, resolution: 480, fps: 10).validate(duration: 2))
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input.mov")
        try await TestMedia.video(to: source, color: .blue, duration: 0.5)
        var project = StudioProject()
        project.ratio = .square
        project.clips = [VideoSegment(url: source, start: 0, end: 0.5)]
        let options = ExportOptions(format: .mp4, codec: .hevc, resolution: 480, fps: 24, bitrateMbps: 5)
        let rendered = try await MediaComposer.build(project, options: options)
        let url = root.appendingPathComponent("hevc.mp4")
        let probe = try AVAssetWriter(outputURL: root.appendingPathComponent("probe.mp4"), fileType: .mp4)
        guard probe.canApply(outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: 480,
            AVVideoHeightKey: 480,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 5_000_000]
        ], forMediaType: .video) else {
            throw XCTSkip("Simulator does not expose an HEVC encoder; verify on a physical iPhone")
        }
        try await ConfiguredExporter.export(rendered, options: options, to: url)
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(videoTracks.first)
        let descriptions = try await track.load(.formatDescriptions)
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(descriptions[0]), kCMVideoCodecType_HEVC)
        let frameRate = try await track.load(.nominalFrameRate)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(Double(frameRate), 24, accuracy: 0.1)
        XCTAssertEqual(duration, 0.5, accuracy: 0.08)
        let generator = AVAssetImageGenerator(asset: asset)
        let (image, _) = try await generator.image(at: MediaComposer.time(0.25))
        XCTAssertGreaterThan(pixel(image, x: image.width / 2, y: image.height / 2)[2], 170)
    }
    func testNativeAudioOverlayDragGeometryAndClamping() {
        XCTAssertEqual(TimelineSurface.clampedTrackOffset(start: 1, dragPoints: 80, zoom: 40,
            timelineDuration: 8, trackDuration: 3), 3, accuracy: 0.001)
        XCTAssertEqual(TimelineSurface.clampedTrackOffset(start: 1, dragPoints: 500, zoom: 40,
            timelineDuration: 8, trackDuration: 3), 5, accuracy: 0.001)
        XCTAssertEqual(TimelineSurface.clampedTrackOffset(start: 1, dragPoints: -500, zoom: 40,
            timelineDuration: 8, trackDuration: 3), 0, accuracy: 0.001)
        XCTAssertEqual(TimelineSurface.clampedTrackOffset(start: 1, dragPoints: .nan, zoom: 40,
            timelineDuration: 8, trackDuration: 3), 0, accuracy: 0.001)
        var project = StudioProject()
        project.clips = [VideoSegment(url: URL(fileURLWithPath: "/main.mov"), start: 0, end: 8)]
        let music = AudioSegment(url: URL(fileURLWithPath: "/music.caf"), offset: 1, sourceDuration: 3)
        let overlay = OverlaySegment(clip: VideoSegment(url: URL(fileURLWithPath: "/pip.mov"), start: 0, end: 2), offset: 3)
        project.audio = [music]; project.overlays = [overlay]
        let view = TimelineSurface(frame: CGRect(x: 0, y: 0, width: 390, height: 192))
        view.layoutIfNeeded()
        view.apply(project: project, selected: project.clips[0].id, thumbnails: [:], zoom: 40, playhead: 2, enabled: true)
        let musicHandle = view.subviews.first { $0.accessibilityIdentifier == "audioTrack_" + music.id.uuidString }
        let overlayHandle = view.subviews.first { $0.accessibilityIdentifier == "overlayTrack_" + overlay.id.uuidString }
        XCTAssertNotNil(musicHandle)
        XCTAssertNotNil(overlayHandle)
        XCTAssertEqual(musicHandle?.frame.minX ?? -1, 155, accuracy: 0.5)
        XCTAssertEqual(overlayHandle?.frame.minX ?? -1, 235, accuracy: 0.5)
        XCTAssertEqual(musicHandle?.frame.width ?? -1, 120, accuracy: 0.5)
        XCTAssertEqual(overlayHandle?.frame.width ?? -1, 80, accuracy: 0.5)
        // Source audio belongs to the canvas, not a movable handle.
        XCTAssertEqual(view.subviews.filter { ($0.accessibilityIdentifier ?? "").hasPrefix("audioTrack_") }.count, 1)
    }

    @MainActor func testAudioAndOverlayTimelineEditingPersistsAndChangesExport() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let red = root.appendingPathComponent("red.mov")
        let blue = root.appendingPathComponent("blue.mov")
        let tone = root.appendingPathComponent("tone.caf")
        try await TestMedia.video(to: red, color: .red, duration: 3)
        try await TestMedia.video(to: blue, color: .blue, duration: 2)
        try TestMedia.audio(to: tone, duration: 3)
        var project = StudioProject()
        project.clips = [VideoSegment(url: red, start: 0, end: 3)]
        let audio = AudioSegment(url: tone, sourceDuration: 3)
        let overlay = OverlaySegment(clip: VideoSegment(url: blue, start: 0, end: 2))
        project.audio = [audio]; project.overlays = [overlay]
        let store = ProjectStore(root: root)
        let model = EditorModel(project: project, store: store)
        defer { model.close() }
        model.setAudioTiming(audio.id, offset: 0.6, duration: 0.7)
        model.setOverlayTiming(overlay.id, offset: 1.2, duration: 0.5)
        XCTAssertEqual(model.project.audio[0].offset, 0.6, accuracy: 0.001)
        XCTAssertEqual(model.project.audio[0].duration, 0.7, accuracy: 0.001)
        XCTAssertEqual(model.project.overlays[0].offset, 1.2, accuracy: 0.001)
        XCTAssertEqual(model.project.overlays[0].clip.duration, 0.5, accuracy: 0.001)
        let saved = try XCTUnwrap(store.list().first)
        XCTAssertEqual(saved.audio[0].duration, 0.7, accuracy: 0.001)
        XCTAssertEqual(saved.overlays[0].offset, 1.2, accuracy: 0.001)
        model.undo()
        XCTAssertEqual(model.project.overlays[0].clip.duration, 2, accuracy: 0.001)
        model.redo()
        XCTAssertEqual(model.project.overlays[0].clip.duration, 0.5, accuracy: 0.001)
        let rendered = try await MediaComposer.build(model.project)
        let output = root.appendingPathComponent("repositioned.mp4")
        try await MediaComposer.export(rendered, to: output)
        let asset = AVURLAsset(url: output)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (before, _) = try await generator.image(at: MediaComposer.time(0.3))
        let (during, _) = try await generator.image(at: MediaComposer.time(1.4))
        XCTAssertGreaterThan(pixel(before, x: 120, y: 18)[0], 180)
        XCTAssertGreaterThan(pixel(during, x: 120, y: 18)[2], 150)
        let beforeAudio = try await audioPeak(asset: asset, start: 0.05, length: 0.2)
        let duringAudio = try await audioPeak(asset: asset, start: 0.65, length: 0.2)
        let afterAudio = try await audioPeak(asset: asset, start: 1.5, length: 0.2)
        XCTAssertLessThan(beforeAudio, 200)
        XCTAssertGreaterThan(duringAudio, 500)
        XCTAssertLessThan(afterAudio, 200)
    }
    func testConfiguredMovieContainersResolutionFPSAndMixedAudio() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let red = root.appendingPathComponent("red.mov"), blue = root.appendingPathComponent("blue.mov"), tone = root.appendingPathComponent("tone.caf")
        try await TestMedia.video(to: red, color: .red, duration: 1)
        try await TestMedia.video(to: blue, color: .blue, duration: 1, rotated: true)
        try TestMedia.audio(to: tone, duration: 2)
        var project = StudioProject(); project.ratio = .square
        project.clips = [VideoSegment(url: red, start: 0, end: 1), VideoSegment(url: blue, start: 0, end: 1)]
        project.audio = [AudioSegment(url: tone, sourceDuration: 2)]
        for (format, fps) in [(ExportFormat.mp4, 24), (.mov, 60)] {
            let options = ExportOptions(format: format, resolution: 480, fps: fps, bitrateMbps: 5)
            let rendered = try await MediaComposer.build(project, options: options)
            let output = root.appendingPathComponent("output." + format.fileExtension)
            try await ConfiguredExporter.export(rendered, options: options, to: output)
            let asset = AVURLAsset(url: output)
            let video = try await asset.loadTracks(withMediaType: .video)[0]
            let size = try await video.load(.naturalSize), rate = try await video.load(.nominalFrameRate)
            XCTAssertEqual(size, CGSize(width: 480, height: 480)); XCTAssertEqual(Double(rate), Double(fps), accuracy: 0.1)
            let duration = try await asset.load(.duration).seconds; XCTAssertEqual(duration, 2, accuracy: 0.06)
            let peak = try await audioPeak(asset: asset, start: 0.2, length: 0.5); XCTAssertGreaterThan(peak, 500)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let (first, _) = try await generator.image(at: MediaComposer.time(0.2)); let (last, _) = try await generator.image(at: MediaComposer.time(1.5))
            XCTAssertGreaterThan(pixel(first, x: 240, y: 240)[0], 180); XCTAssertGreaterThan(pixel(last, x: 240, y: 240)[2], 180)
            let bytes = try Data(contentsOf: output); XCTAssertTrue(String(decoding: bytes.prefix(64), as: UTF8.self).contains(format == .mov ? "qt  " : "mp4"))
        }
    }
    func testGIFContainsRealOrderedFramesAndLoopTiming() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let red = root.appendingPathComponent("red.mov"), blue = root.appendingPathComponent("blue.mov")
        try await TestMedia.video(to: red, color: .red, duration: 0.4); try await TestMedia.video(to: blue, color: .blue, duration: 0.4)
        var project = StudioProject(); project.clips = [VideoSegment(url: red, start: 0, end: 0.4), VideoSegment(url: blue, start: 0, end: 0.4)]
        let options = ExportOptions(format: .gif, resolution: 240, fps: 10)
        let rendered = try await MediaComposer.build(project, options: options)
        let url = root.appendingPathComponent("output.gif"); try await ConfiguredExporter.export(rendered, options: options, to: url)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 8)
        let first = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)), last = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 7, nil))
        XCTAssertEqual(first.height, 240); XCTAssertEqual(first.width, 426)
        XCTAssertGreaterThan(pixel(first, x: 100, y: 100)[0], 180); XCTAssertGreaterThan(pixel(last, x: 100, y: 100)[2], 180)
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        let gif = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary as String] as? [String: Any])
        XCTAssertEqual((gif[kCGImagePropertyGIFDelayTime as String] as? Double) ?? 0, 0.1, accuracy: 0.001)
        XCTAssertThrowsError(try ExportOptions(format: .gif, resolution: 480, fps: 10).validate(duration: 31))
    }
    @MainActor func testSeekBurstReorderUndoAndCenteredGeometry() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("input.mov"); try await TestMedia.video(to: source, color: .red, duration: 8)
        let model = EditorModel(store: ProjectStore(root: root)); defer { model.close() }
        await model.add(url: source); try await waitForPreview(model)
        model.beginScrub()
        for index in 0..<200 { model.seek(Double(index) / 25) }
        model.endScrub(6.125)
        for _ in 0..<100 {
            if abs((model.player?.currentTime().seconds ?? 0) - 6.125) < 0.02 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(model.player?.currentTime().seconds ?? 0, 6.125, accuracy: 0.02)
        XCTAssertEqual(model.playhead, 6.125, accuracy: 0.02); XCTAssertFalse(model.playing)
        model.duplicateSelected(); model.trim(model.clips[1].id, end: 3)
        let original = model.clips.map(\.id), moving = model.clips[1].id
        let originalClips = model.clips
        let undoCount = model.undoStack.count
        model.moveClip(moving, to: 0)
        XCTAssertEqual(model.playhead, 6.125, accuracy: 0.02, "Moving a clip must not jump the fixed timeline playhead")
        XCTAssertEqual(model.clips, Array(originalClips.reversed())); XCTAssertEqual(model.undoStack.count, undoCount + 1)
        model.undo(); XCTAssertEqual(model.clips.map(\.id), original); model.redo(); XCTAssertEqual(model.clips.first?.id, moving)
        let view = TimelineSurface(frame: CGRect(x: 0, y: 0, width: 390, height: 128)); view.layoutIfNeeded()
        view.apply(project: model.project, selected: moving, thumbnails: [:], zoom: 24, playhead: 5, enabled: true)
        XCTAssertEqual(view.collection.contentOffset.x + view.collection.contentInset.left, 120, accuracy: 0.01)
        view.frame.size.width = 700; view.layoutIfNeeded()
        XCTAssertEqual(view.collection.contentOffset.x + view.collection.contentInset.left, 120, accuracy: 0.01)
        view.apply(project: model.project, selected: moving, thumbnails: [:], zoom: 80, playhead: 5, enabled: true)
        XCTAssertEqual(view.collection.contentOffset.x + view.collection.contentInset.left, 400, accuracy: 0.01)
    }
    func testMagneticScrubSnapsOnlyNearEditedClipBoundaries() {
        let clips = [
            VideoSegment(url: URL(fileURLWithPath: "/first.mov"), start: 0, end: 3, sourceDuration: 3),
            VideoSegment(url: URL(fileURLWithPath: "/second.mov"), start: 0, end: 2, sourceDuration: 2)
        ]
        // At 50 pt/s, a 10 pt magnetic zone spans 0.2 seconds either side of a cut.
        XCTAssertEqual(TimelineSurface.snappedTime(3.15, in: clips, zoom: 50), 3, accuracy: 0.0001)
        XCTAssertEqual(TimelineSurface.snappedTime(3.30, in: clips, zoom: 50), 3.30, accuracy: 0.0001)
        XCTAssertEqual(TimelineSurface.snappedTime(4.86, in: clips, zoom: 50), 5, accuracy: 0.0001)
        XCTAssertEqual(TimelineSurface.snappedTime(2.7, in: clips, zoom: 20), 3, accuracy: 0.0001)
        XCTAssertEqual(TimelineSurface.snappedTime(2.7, in: clips, zoom: 80), 2.7, accuracy: 0.0001)
    }

    func testNativePinchZoomBoundsAndCenterAnchor() {
        XCTAssertEqual(TimelineSurface.clampedZoom(start: 24, scale: 2), 48, accuracy: 0.0001)
        XCTAssertEqual(TimelineSurface.clampedZoom(start: 24, scale: 0.5), 12, accuracy: 0.0001)
        XCTAssertEqual(TimelineSurface.clampedZoom(start: 60, scale: 3), 80, accuracy: 0.0001)
        XCTAssertEqual(TimelineSurface.clampedZoom(start: 10, scale: 0.1), 8, accuracy: 0.0001)
        XCTAssertEqual(TimelineSurface.clampedZoom(start: 24, scale: .nan), 24, accuracy: 0.0001)
        let project = StudioProject()
        let timeline = TimelineSurface(frame: CGRect(x: 0, y: 0, width: 393, height: 128))
        timeline.layoutIfNeeded()
        timeline.apply(project: project, selected: nil, thumbnails: [:], zoom: 24, playhead: 0, enabled: true)
        let initialAnchor = timeline.collection.contentOffset.x + timeline.collection.contentInset.left
        // UIKit snaps scroll offsets to the display pixel grid (e.g. 1/6 pt on odd-width views).
        // A sub-point tolerance allows pixel rounding without allowing a visible cursor jump.
        XCTAssertEqual(initialAnchor, 0, accuracy: 0.5)
        timeline.apply(project: project, selected: nil, thumbnails: [:], zoom: 48, playhead: 0, enabled: true)
        let zoomedAnchor = timeline.collection.contentOffset.x + timeline.collection.contentInset.left
        XCTAssertEqual(zoomedAnchor, initialAnchor, accuracy: 0.01, "Zoom must keep the same centered playhead anchor")
        XCTAssertEqual(zoomedAnchor, 0, accuracy: 0.5)
    }

    func testCancelledExportRemovesPartialOutput() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("long.mov"); try await TestMedia.video(to: source, color: .green, duration: 20)
        var project = StudioProject(); project.clips = [VideoSegment(url: source, start: 0, end: 20)]
        let options = ExportOptions(resolution: 720, fps: 60)
        let rendered = try await MediaComposer.build(project, options: options), url = root.appendingPathComponent("cancel.mp4")
        let task = Task { try await ConfiguredExporter.export(rendered, options: options, to: url) }
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: url.path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Exercise cancellation after creating a partial movie")
        task.cancel()
        do { try await task.value; XCTFail("Cancellation must stop export") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testEveryVideoResolutionAndFrameRateCreatesPlayableH264() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("short.mov"); try await TestMedia.video(to: source, color: .blue, duration: 0.2)
        var project = StudioProject(); project.ratio = .landscape; project.clips = [VideoSegment(url: source, start: 0, end: 0.2)]
        for (resolution, fps, bitrate) in [(720, 25, 10), (1080, 30, 20), (1440, 50, 50), (2160, 60, 100)] {
            let options = ExportOptions(resolution: resolution, fps: fps, bitrateMbps: bitrate)
            let rendered = try await MediaComposer.build(project, options: options), output = root.appendingPathComponent("\(resolution).mp4")
            try await ConfiguredExporter.export(rendered, options: options, to: output)
            let asset = AVURLAsset(url: output), track = try await asset.loadTracks(withMediaType: .video)[0]
            let size = try await track.load(.naturalSize), rate = try await track.load(.nominalFrameRate)
            XCTAssertEqual(size.height, CGFloat(resolution)); XCTAssertEqual(size.width, CGFloat((Double(resolution) * 16 / 9 / 2).rounded() * 2))
            XCTAssertEqual(Double(rate), Double(fps), accuracy: 0.1)
            let reader = try AVAssetReader(asset: asset)
            let outputFrames = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]); reader.add(outputFrames)
            XCTAssertTrue(reader.startReading())
            var count = 0
            while let sample = outputFrames.copyNextSampleBuffer() {
                XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample).seconds, Double(count) / Double(fps), accuracy: 0.0001)
                count += 1
            }
            XCTAssertEqual(count, Int((0.2 * Double(fps)).rounded())); XCTAssertEqual(reader.status, .completed)
            let descriptions = try await track.load(.formatDescriptions)
            XCTAssertEqual(CMFormatDescriptionGetMediaSubType(descriptions[0]), kCMVideoCodecType_H264)
            let generator = AVAssetImageGenerator(asset: asset); generator.maximumSize = CGSize(width: 80, height: 80)
            let (frame, _) = try await generator.image(at: .zero)
            XCTAssertGreaterThan(pixel(frame, x: frame.width / 2, y: frame.height / 2)[2], 180)
        }
    }

}
