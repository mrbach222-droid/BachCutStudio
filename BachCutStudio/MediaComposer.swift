import AVFoundation
import UIKit

enum StudioError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
struct RenderedProject {
    let composition: AVMutableComposition
    let video: AVMutableVideoComposition
    let audio: AVMutableAudioMix
}
enum MediaComposer {
    static func time(_ value: Double) -> CMTime { CMTime(seconds: value, preferredTimescale: 600) }
    static func fittedTransform(size: CGSize, transform: CGAffineTransform, canvas: CGSize, inset: CGRect? = nil) -> CGAffineTransform {
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        let box = inset ?? CGRect(origin: .zero, size: canvas)
        let scale = min(box.width / max(1, rect.width), box.height / max(1, rect.height))
        return transform.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: box.minX + (box.width - rect.width * scale) / 2,
                                          y: box.minY + (box.height - rect.height * scale) / 2))
    }
    static func canvasSize(ratio: CanvasRatio, natural: CGSize, transform: CGAffineTransform) -> CGSize {
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        let aspect: Double
        switch ratio { case .original: aspect = Double(abs(rect.width) / max(1, abs(rect.height)))
        case .portrait: aspect = 9.0 / 16; case .landscape: aspect = 16.0 / 9; case .square: aspect = 1 }
        let edge = min(1920.0, max(2, Double(max(abs(rect.width), abs(rect.height)))))
        let w = aspect >= 1 ? edge : edge * aspect
        let h = aspect >= 1 ? edge / aspect : edge
        return CGSize(width: max(2, floor(w / 2) * 2), height: max(2, floor(h / 2) * 2))
    }
    static func build(_ project: StudioProject) async throws -> RenderedProject {
        guard !project.clips.isEmpty, project.duration > 0 else { throw StudioError.message("Thêm video trước khi xuất") }
        let composition = AVMutableComposition()
        guard let base = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let baseAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw StudioError.message("Không tạo được timeline")
        }
        var canvas = CGSize.zero
        var instructions: [AVMutableVideoCompositionInstruction] = []
        let baseMix = AVMutableAudioMixInputParameters(track: baseAudio)
        var mixes: [AVAudioMixInputParameters] = [baseMix]
        var cursor = 0.0
        for clip in project.clips {
            let asset = AVURLAsset(url: clip.url)
            let sourceDuration = try await asset.load(.duration).seconds
            guard clip.start >= 0, clip.end <= sourceDuration + 0.02, clip.duration > 0,
                  let source = try await asset.loadTracks(withMediaType: .video).first else {
                throw StudioError.message("Video bị thiếu hoặc đoạn cắt vượt độ dài nguồn")
            }
            let transform = try await source.load(.preferredTransform)
            let size = try await source.load(.naturalSize)
            if canvas == .zero { canvas = canvasSize(ratio: project.ratio, natural: size, transform: transform) }
            let sourceRange = CMTimeRange(start: time(clip.start), duration: time(clip.end - clip.start))
            try base.insertTimeRange(sourceRange, of: source, at: time(cursor))
            base.scaleTimeRange(CMTimeRange(start: time(cursor), duration: sourceRange.duration), toDuration: time(clip.duration))
            if let sound = try await asset.loadTracks(withMediaType: .audio).first {
                // Use the intersection: some video containers have a shorter audio track.
                let intersection = CMTimeRangeGetIntersection(sourceRange, try await sound.load(.timeRange))
                if intersection.duration.seconds > 0 {
                    let destination = cursor + (intersection.start.seconds - clip.start) / clip.speed
                    try baseAudio.insertTimeRange(intersection, of: sound, at: time(destination))
                    baseAudio.scaleTimeRange(CMTimeRange(start: time(destination), duration: intersection.duration), toDuration: time(intersection.duration.seconds / clip.speed))
                }
            }
            baseMix.setVolume(Float(clip.volume), at: time(cursor))
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: base)
            layer.setTransform(fittedTransform(size: size, transform: transform, canvas: canvas), at: time(cursor))
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: time(cursor), duration: time(clip.duration))
            instruction.backgroundColor = UIColor.black.cgColor
            instruction.layerInstructions = [layer]
            instructions.append(instruction)
            cursor += clip.duration
        }
        // V2 picture-in-picture is an actual second video track, included in preview and export.
        var overlayLayers: [(Double, Double, AVMutableVideoCompositionLayerInstruction)] = []
        for overlay in project.overlays where overlay.offset < project.duration {
            let clip = overlay.clip
            let asset = AVURLAsset(url: clip.url)
            guard let source = try await asset.loadTracks(withMediaType: .video).first,
                  let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw StudioError.message("Không đọc được lớp phủ") }
            let start = max(0, overlay.offset), length = min(clip.duration, project.duration - start)
            guard length > 0 else { continue }
            let sourceRange = CMTimeRange(start: time(clip.start), duration: time(length * clip.speed))
            try track.insertTimeRange(sourceRange, of: source, at: time(start))
            track.scaleTimeRange(CMTimeRange(start: time(start), duration: sourceRange.duration), toDuration: time(length))
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            let box = CGRect(x: canvas.width * 0.60, y: canvas.height * 0.06, width: canvas.width * 0.34, height: canvas.height * 0.34)
            layer.setTransform(fittedTransform(size: try await source.load(.naturalSize), transform: try await source.load(.preferredTransform), canvas: canvas, inset: box), at: time(start))
            overlayLayers.append((start, start + length, layer))
        }
        // Split instructions at all overlay boundaries. No inactive track is requested by the compositor.
        let boundaries = Set(instructions.flatMap { [$0.timeRange.start.seconds, $0.timeRange.end.seconds] } + overlayLayers.flatMap { [$0.0, $0.1] }).sorted()
        var finalInstructions: [AVMutableVideoCompositionInstruction] = []
        for (start, end) in zip(boundaries, boundaries.dropFirst()) where end - start > 0.0001 {
            let mid = (start + end) / 2
            guard let baseInstruction = instructions.first(where: { $0.timeRange.start.seconds <= mid && $0.timeRange.end.seconds > mid }) else { continue }
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: time(start), duration: time(end - start))
            instruction.backgroundColor = UIColor.black.cgColor
            instruction.layerInstructions = overlayLayers.filter { $0.0 <= mid && $0.1 > mid }.reversed().map { $0.2 } + baseInstruction.layerInstructions
            finalInstructions.append(instruction)
        }
        for sound in project.audio where sound.offset < project.duration {
            let asset = AVURLAsset(url: sound.url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first,
                  let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw StudioError.message("Tệp không có âm thanh") }
            let start = max(0, sound.offset)
            let available = try await source.load(.timeRange)
            let length = min(available.duration.seconds, project.duration - start)
            guard length > 0 else { continue }
            try track.insertTimeRange(CMTimeRange(start: available.start, duration: time(length)), of: source, at: time(start))
            let mix = AVMutableAudioMixInputParameters(track: track)
            mix.setVolume(Float(min(1, max(0, sound.volume))), at: time(start)); mixes.append(mix)
        }
        let video = AVMutableVideoComposition()
        video.renderSize = canvas; video.frameDuration = CMTime(value: 1, timescale: 30); video.instructions = finalInstructions
        let audio = AVMutableAudioMix(); audio.inputParameters = mixes
        return RenderedProject(composition: composition, video: video, audio: audio)
    }
    static func export(_ rendered: RenderedProject, to url: URL) async throws {
        guard let session = AVAssetExportSession(asset: rendered.composition, presetName: AVAssetExportPresetHighestQuality) else { throw StudioError.message("Không khởi tạo được bộ xuất") }
        session.outputURL = url; session.outputFileType = .mp4; session.shouldOptimizeForNetworkUse = true
        session.videoComposition = rendered.video; session.audioMix = rendered.audio
        await session.export()
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw session.error ?? StudioError.message("Xuất video thất bại")
        }
    }
}
