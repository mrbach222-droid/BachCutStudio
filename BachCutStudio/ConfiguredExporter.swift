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
            try Task.checkCancellation()
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
        let writer = try AVAssetWriter(outputURL: url, fileType: options.format.fileType)
        writer.shouldOptimizeForNetworkUse = true
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: options.bitrateMbps * 1_000_000,
            AVVideoExpectedSourceFrameRateKey: options.fps,
            AVVideoMaxKeyFrameIntervalKey: options.fps * 2
        ]
        // The H.264 profile constant is not valid for HEVC. Let the hardware choose
        // an HEVC profile appropriate to the render size and selected frame rate.
        if options.codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        let settings: [String: Any] = [
            AVVideoCodecKey: options.codec.avCodec,
            AVVideoWidthKey: Int(rendered.video.renderSize.width),
            AVVideoHeightKey: Int(rendered.video.renderSize.height),
            AVVideoCompressionPropertiesKey: compression
        ]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw StudioError.message("Thiết bị không hỗ trợ mã hóa \(options.codec.rawValue) ở chất lượng đã chọn. Hãy giảm độ phân giải/fps hoặc chọn H.264.")
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings); videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw StudioError.message("Không tạo được kênh xuất video") }; writer.add(videoInput)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: Int(rendered.video.renderSize.width), kCVPixelBufferHeightKey as String: Int(rendered.video.renderSize.height)])
        let frames = FrameResampler(output: video)
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
        let frameCount = Int(ceil(length * Double(options.fps) - 0.000001))
        var frameIndex = 0
        while !videoDone || !audioDone {
            try Task.checkCancellation()
            guard writer.status == .writing, reader.status != .failed else { throw writer.error ?? reader.error ?? StudioError.message("Xuất bị gián đoạn") }
            var advanced = false
            if !videoDone && videoInput.isReadyForMoreMediaData {
                try autoreleasepool {
                    if frameIndex < frameCount {
                        let stamp = CMTime(value: Int64(frameIndex), timescale: Int32(options.fps))
                        guard let buffer = frames.buffer(at: stamp), adaptor.append(buffer, withPresentationTime: stamp) else { throw writer.error ?? reader.error ?? StudioError.message("Không ghi được khung hình") }
                        frameIndex += 1
                        let fraction = min(0.99, Double(frameIndex) / Double(frameCount))
                        if fraction - lastProgress >= 0.01 { lastProgress = fraction; progress(fraction) }
                    } else {
                        // Reader may retain a final source frame when downsampling. Exhaust it before checking completion.
                        while video.copyNextSampleBuffer() != nil { try Task.checkCancellation() }
                        videoInput.markAsFinished(); videoDone = true
                    }
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

// Hold one current frame and one look-ahead sample. The writer receives an explicit
// constant frame-rate grid even when the reader emits only the source's 30 fps.
private final class FrameResampler {
    private let output: AVAssetReaderVideoCompositionOutput
    private var current: CMSampleBuffer?
    private var next: CMSampleBuffer?
    private var ended = false
    init(output: AVAssetReaderVideoCompositionOutput) { self.output = output }
    func buffer(at time: CMTime) -> CVPixelBuffer? {
        if current == nil { current = output.copyNextSampleBuffer() }
        if next == nil && !ended { readNext() }
        while let sample = next, CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), time) <= 0 {
            current = sample; readNext()
        }
        return current.flatMap { CMSampleBufferGetImageBuffer($0) }
    }
    private func readNext() { next = output.copyNextSampleBuffer(); if next == nil { ended = true } }
}
