import XCTest
import AVFoundation
import UIKit
@testable import BachCutStudio

final class AudioEnvelopeTests: XCTestCase {
    func testBoundsLegacyDecodeAndTrimNormalization() throws {
        let a = AudioEnvelope.bounded(fadeIn: 4, fadeOut: 2, length: 3)
        // Preserve the requested phase ratio without overflowing the sum.
        XCTAssertEqual(a.fadeIn, 2, accuracy: 0.001); XCTAssertEqual(a.fadeOut, 1, accuracy: 0.001)
        let b = AudioEnvelope.bounded(fadeIn: .nan, fadeOut: -2, length: 3)
        XCTAssertEqual(b.fadeIn, 0); XCTAssertEqual(b.fadeOut, 0)
        let c = AudioEnvelope.bounded(fadeIn: 1, fadeOut: 1, length: 0)
        XCTAssertEqual(c.fadeIn, 0); XCTAssertEqual(c.fadeOut, 0)
        let sound = AudioSegment(url: URL(fileURLWithPath: "/tone.caf"), sourceDuration: 8)
        var fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(sound)) as! [String: Any]
        fields.removeValue(forKey: "fadeIn"); fields.removeValue(forKey: "fadeOut")
        let old = try JSONDecoder().decode(AudioSegment.self, from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertEqual(old.fadeIn, 0); XCTAssertEqual(old.fadeOut, 0)
        var trimmed = AudioSegment(url: sound.url, sourceDuration: 8, trimDuration: 2, fadeIn: 2, fadeOut: 2)
        trimmed.normalize(); XCTAssertEqual(trimmed.fadeIn, 1); XCTAssertEqual(trimmed.fadeOut, 1)
    }
    @MainActor func testEnvelopeHistorySaveTrimAndAbsoluteOffset() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(root: root); try store.prepare()
        var p = StudioProject(); p.clips = [VideoSegment(url: store.mediaDirectory.appendingPathComponent("video.mov"), start: 0, end: 8)]
        p.audio = [AudioSegment(url: store.mediaDirectory.appendingPathComponent("tone.caf"), offset: 1, sourceDuration: 8, trimDuration: 4, sourceStart: 2)]
        let model = EditorModel(project: p, store: store); defer { model.close() }
        let id = p.audio[0].id
        model.setAudioEnvelope(id, volume: 0.5, fadeIn: 1, fadeOut: 1)
        XCTAssertEqual(model.undoStack.count, 1); XCTAssertEqual(model.project.audio[0].fadeIn, 1)
        XCTAssertEqual(model.project.audio[0].fadeOut, 1); XCTAssertEqual(model.project.audio[0].volume, 0.5)
        XCTAssertEqual(model.project.audio[0].sourceStart, 2); XCTAssertEqual(model.project.audio[0].offset, 1)
        XCTAssertEqual(try store.list().first?.audio, model.project.audio)
        model.undo(); XCTAssertEqual(model.project.audio, p.audio); XCTAssertTrue(model.undoStack.isEmpty)
        model.redo(); XCTAssertEqual(model.project.audio[0].fadeOut, 1)
        model.setAudioTiming(id, offset: 3, duration: 1, sourceStart: 4)
        XCTAssertEqual(model.project.audio[0].fadeIn, 0.5); XCTAssertEqual(model.project.audio[0].fadeOut, 0.5)
        XCTAssertEqual(model.project.audio[0].offset, 3); XCTAssertEqual(model.project.audio[0].sourceStart, 4)
        let prior = model.project
        model.setAudioEnvelope(id, volume: .nan, fadeIn: 1, fadeOut: 1)
        XCTAssertEqual(model.project, prior)
    }
    func rms(_ asset: AVAsset, mix: AVAudioMix? = nil, windows: [(Double, Double)]) async throws -> [Double] {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertFalse(tracks.isEmpty)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        output.audioMix = mix; reader.add(output); XCTAssertTrue(reader.startReading())
        var sums = [Double](repeating: 0, count: windows.count), counts = [Int](repeating: 0, count: windows.count)
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            var data = Data(count: CMBlockBufferGetDataLength(block))
            let byteCount = data.count
            data.withUnsafeMutableBytes { ptr in _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount, destination: ptr.baseAddress!) }
            data.withUnsafeBytes { ptr in
                for (index, value) in ptr.bindMemory(to: Float.self).enumerated() {
                    let time = start + Double(index) / 44100
                    for i in windows.indices where time >= windows[i].0 && time < windows[i].1 {
                        sums[i] += Double(value) * Double(value); counts[i] += 1
                    }
                }
            }
        }
        XCTAssertEqual(reader.status, .completed)
        for i in windows.indices { XCTAssertGreaterThan(counts[i], 100) }
        return zip(sums, counts).map { sqrt($0.0 / Double(max(1, $0.1))) }
    }
    func testActualPreviewMixAndBothExportersUseSelectedSourceEnvelope() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("red.mov"), tone = root.appendingPathComponent("tone.caf")
        try await TestMedia.video(to: video, color: .red, duration: 6)
        try TestMedia.audio(to: tone, duration: 7, silentPrefix: 2)
        var p = StudioProject(); p.clips = [VideoSegment(url: video, start: 0, end: 6)]
        p.audio = [AudioSegment(url: tone, offset: 1, sourceDuration: 7, volume: 0.5, trimDuration: 4, sourceStart: 2, fadeIn: 1, fadeOut: 1)]
        let windows = [(1.08, 1.18), (2.3, 2.5), (4.82, 4.92)]
        let rendered = try await MediaComposer.build(p)
        let preview = try await rms(rendered.composition, mix: rendered.audio, windows: windows)
        let simple = root.appendingPathComponent("preview.mp4")
        try await MediaComposer.export(rendered, to: simple)
        var options = ExportOptions(); options.resolution = 480; options.fps = 30
        let configured = try await MediaComposer.build(p, options: options)
        let output = root.appendingPathComponent("configured.mp4")
        try await ConfiguredExporter.export(configured, options: options, to: output, progress: { _ in })
        let simpleRMS = try await rms(AVURLAsset(url: simple), windows: windows)
        let outputRMS = try await rms(AVURLAsset(url: output), windows: windows)
        for levels in [preview, simpleRMS, outputRMS] {
            XCTAssertGreaterThan(levels[1], 0.045); XCTAssertLessThan(levels[1], 0.095, "0.5 gain must reach decoded audio")
            XCTAssertLessThan(levels[0], levels[1] * 0.3, "Fade-in must affect actual samples after the selected source start")
            XCTAssertLessThan(levels[2], levels[1] * 0.3, "Fade-out must end at the trimmed interval, including timeline offset")
        }
    }
}
