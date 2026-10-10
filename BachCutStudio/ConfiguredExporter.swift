import AVFoundation
import ImageIO
import CoreImage
import UniformTypeIdentifiers

// The reader, writer and ImageIO destination are created and used on the export worker.
// Only immutable configuration and cancellation cross the task boundary.
final class ConfiguredExporter: @unchecked Sendable {
    let rendered: RenderedProject
    let options: ExportOptions
    let url: URL
    let progress: @Sendable (Double) -> Void
    init(rendered: RenderedProject, options: ExportOptions, url: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.rendered = rendered; self.options = options; self.url = url; self.progress = progress
    }
    static func export(_ rendered: RenderedProject, options: ExportOptions, to url: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let job = ConfiguredExporter(rendered: rendered, options: options, url: url, progress: progress)
        let worker = Task.detached(priority: .userInitiated) { try await job.run() }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    private func run() async throws {
        do {
            try options.validate(duration: rendered.composition.duration.seconds)
            if options.format == .gif { try await gif() } else { try await movie() }
            try Task.checkCancellation(); progress(1)
        } catch { try? FileManager.default.removeItem(at: url); throw error }
    }
    private func reader() throws -> (AVAssetReader, AVAssetReaderVideoCompositionOutput) {
        let reader = try AVAssetReader(asset: rendered.composition)
        let video = AVAssetReaderVideoCompositionOutput(videoTracks: rendered.composition.tracks(withMediaType: .video), videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        video.videoComposition = rendered.video; video.alwaysCopiesSampleData = false
        guard reader.canAdd(video) else { throw StudioError.message("Không đọc được khung hình xuất") }; reader.add(video)
        return (reader, video)
    }
    private func movie() async throws {
        let (reader, video) = try reader()
        let writer = try AVAssetWriter(outputURL: url, fileType: options.fileType)
        writer.shouldOptimizeForNetworkUse = true
        let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(rendered.video.renderSize.width), AVVideoHeightKey: Int(rendered.video.renderSize.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: options.bitrateMbps * 1_000_000, AVVideoExpectedSourceFrameRateKey: options.fps, AVVideoMaxKeyFrameIntervalKey: options.fps * 2, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel]]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else { throw StudioError.message("Thiết bị không hỗ trợ chất lượng đã chọn. Hãy giảm độ phân giải hoặc fps.") }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings); videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw StudioError.message("Không tạo được kênh xuất video") }; writer.add(videoInput)
        var audioOutput: AVAssetReaderAudioMixOutput?
        var audioInput: AVAssetWriterInput?
        let tracks = rendered.composition.tracks(withMediaType: .audio)
        if !tracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
            output.audioMix = rendered.audio; output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000]); input.expectsMediaDataInRealTime = false
            guard reader.canAdd(output), writer.canAdd(input) else { throw StudioError.message("Không xuất được âm thanh") }
            reader.add(output); writer.add(input); audioOutput = output; audioInput = input
        }
        guard reader.startReading(), writer.startWriting() else { throw reader.error ?? writer.error ?? StudioError.message("Không bắt đầu được bộ xuất") }
        writer.startSession(atSourceTime: .zero)
        defer { if reader.status == .reading { reader.cancelReading() }; if writer.status == .writing { writer.cancelWriting() } }
        var videoDone = false, audioDone = audioInput == nil
        var lastProgress = 0.0
        let length = rendered.composition.duration.seconds
        while !videoDone || !audioDone {
            try Task.checkCancellation()
            guard writer.status == .writing, reader.status != .failed else { throw writer.error ?? reader.error ?? StudioError.message("Xuất bị gián đoạn") }
            var advanced = false
            if !videoDone && videoInput.isReadyForMoreMediaData {
                try autoreleasepool {
                    if let sample = video.copyNextSampleBuffer() {
                        guard videoInput.append(sample) else { throw writer.error ?? StudioError.message("Không ghi được khung hình") }
                        let fraction = min(0.99, CMSampleBufferGetPresentationTimeStamp(sample).seconds / length)
                        if fraction - lastProgress >= 0.01 { lastProgress = fraction; progress(fraction) }
                    } else { videoInput.markAsFinished(); videoDone = true }
                }
                advanced = true
            }
            if !audioDone, let output = audioOutput, let input = audioInput, input.isReadyForMoreMediaData {
                try autoreleasepool {
                    if let sample = output.copyNextSampleBuffer() {
                        guard input.append(sample) else { throw writer.error ?? StudioError.message("Không ghi được âm thanh") }
                    } else { input.markAsFinished(); audioDone = true }
                }
                advanced = true
            }
            if !advanced { try await Task.sleep(nanoseconds: 2_000_000) }
        }
        guard reader.status == .completed else { throw reader.error ?? StudioError.message("Không đọc hết video nguồn") }
        writer.endSession(atSourceTime: rendered.composition.duration)
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? StudioError.message("Không hoàn tất file xuất") }
    }
    private func gif() async throws {
        let (reader, video) = try reader()
        let length = rendered.composition.duration.seconds
        let count = Int(ceil(length * Double(options.fps)))
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, count, nil) else { throw StudioError.message("Không tạo được GIF") }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        guard reader.startReading() else { throw reader.error ?? StudioError.message("Không đọc được GIF") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        let context = CIContext(options: [.cacheIntermediates: false])
        var frames = 0
        while let sample = video.copyNextSampleBuffer() {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let buffer = CMSampleBufferGetImageBuffer(sample), let image = context.createCGImage(CIImage(cvPixelBuffer: buffer), from: CGRect(origin: .zero, size: rendered.video.renderSize)) else { throw StudioError.message("Không tạo được ảnh GIF") }
                let delay = min(1 / Double(options.fps), max(0.01, length - Double(frames) / Double(options.fps)))
                CGImageDestinationAddImage(destination, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary)
            }
            frames += 1; progress(min(0.99, Double(frames) / Double(count)))
        }
        guard reader.status == .completed, frames == count, CGImageDestinationFinalize(destination) else { throw reader.error ?? StudioError.message("Không hoàn tất GIF") }
    }
}
