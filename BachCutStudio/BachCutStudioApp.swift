import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import UIKit

struct VideoSegment: Identifiable {
    let id = UUID()
    var url: URL
    var start: Double
    var end: Double
    var duration: Double { max(0.01, end - start) }
}

@MainActor final class EditorModel: ObservableObject {
    @Published var clips: [VideoSegment] = []
    @Published var player: AVPlayer?
    @Published var busy = false
    @Published var progress = ""
    @Published var exportedURL: URL?
    @Published var selected: UUID?
    var duration: Double { clips.reduce(0) { $0 + $1.duration } }

    func add(url: URL) async {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + url.pathExtension)
        do {
            try FileManager.default.copyItem(at: url, to: copy)
            let asset = AVURLAsset(url: copy)
            let time = try await asset.load(.duration)
            let length = CMTimeGetSeconds(time)
            guard length.isFinite && length > 0 else { progress = "Video không hợp lệ"; return }
            clips.append(VideoSegment(url: copy, start: 0, end: length))
            selected = clips.last?.id
            await preview()
        } catch { progress = "Không nhập được video: \(error.localizedDescription)" }
    }

    func move(_ offsets: IndexSet, to destination: Int) {
        clips.move(fromOffsets: offsets, toOffset: destination)
        Task { await preview() }
    }
    func delete(at offsets: IndexSet) {
        clips.remove(atOffsets: offsets)
        Task { await preview() }
    }
    func trim(_ id: UUID, side: String, seconds: Double) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        if side == "start" {
            clips[i].start = min(clips[i].end - 0.1, max(0, clips[i].start + seconds))
        } else {
            clips[i].end = max(clips[i].start + 0.1, clips[i].end + seconds)
        }
        Task { await preview() }
    }

    func composition() async throws -> AVMutableComposition {
        let result = AVMutableComposition()
        guard let videoTrack = result.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw NSError(domain: "BachCut", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot create video track"])
        }
        let audioTrack = result.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        var cursor = CMTime.zero
        for clip in clips {
            let asset = AVURLAsset(url: clip.url)
            let sourceVideo = try await asset.loadTracks(withMediaType: .video)
            guard let first = sourceVideo.first else { continue }
            let start = CMTime(seconds: clip.start, preferredTimescale: 600)
            let duration = CMTime(seconds: clip.duration, preferredTimescale: 600)
            try videoTrack.insertTimeRange(CMTimeRange(start: start, duration: duration), of: first, at: cursor)
            if cursor == .zero {
                videoTrack.preferredTransform = try await first.load(.preferredTransform)
            }
            if let sound = try await asset.loadTracks(withMediaType: .audio).first {
                try? audioTrack?.insertTimeRange(CMTimeRange(start: start, duration: duration), of: sound, at: cursor)
            }
            cursor = CMTimeAdd(cursor, duration)
        }
        return result
    }

    func preview() async {
        guard !clips.isEmpty else { player = nil; return }
        do {
            let composition = try await composition()
            player = AVPlayer(playerItem: AVPlayerItem(asset: composition))
        } catch { progress = "Không thể xem trước: \(error.localizedDescription)" }
    }

    func export() async {
        guard !clips.isEmpty else { return }
        busy = true
        progress = "Đang dựng video…"
        defer { busy = false }
        do {
            let composition = try await composition()
            guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
                progress = "Không thể khởi tạo bộ xuất"; return
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("BachCut-\(UUID().uuidString).mp4")
            session.outputURL = url
            session.outputFileType = .mp4
            await session.export()
            if session.status == .completed {
                exportedURL = url
                progress = "Đã xuất MP4 thành công"
            } else {
                progress = session.error?.localizedDescription ?? "Xuất video thất bại"
            }
        } catch { progress = error.localizedDescription }
    }
}

@main struct BachCutStudioApp: App {
    var body: some Scene {
        WindowGroup { StudioHome().preferredColorScheme(.dark) }
    }
}

struct EditorScreen: View {
    @StateObject private var model = EditorModel()
    @State private var importing = false
    @State private var zoom: Double = 10
    private var active: VideoSegment? { model.clips.first(where: { $0.id == model.selected }) }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > geo.size.height
            Group {
                if wide {
                    HStack(spacing: 10) {
                        VStack(spacing: 8) { preview; transport }
                            .frame(width: geo.size.width * 0.39)
                        editingArea
                    }
                } else {
                    VStack(spacing: 8) {
                        preview.frame(height: min(geo.size.height * 0.39, 310))
                        transport
                        editingArea
                    }
                }
            }
            .padding(10)
            .background(Color(red: 0.045, green: 0.055, blue: 0.09))
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.movie, .video, .mpeg4Movie], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { for url in urls { await model.add(url: url) } }
            } else if case .failure(let error) = result { model.progress = error.localizedDescription }
        }
    }

    var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(.black)
            if let player = model.player {
                VideoPlayerView(player: player).clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "film.stack").font(.system(size: 38))
                    Text("Thêm video để bắt đầu").font(.subheadline)
                }.foregroundStyle(.gray)
            }
        }
    }

    var transport: some View {
        HStack {
            Text("BÁCHCUT STUDIO").font(.system(size: 12, weight: .heavy, design: .rounded)).foregroundStyle(.cyan)
            Spacer()
            Button { model.player?.seek(to: .zero) } label: { Image(systemName: "backward.end.fill") }
            Button {
                if model.player?.timeControlStatus == .playing { model.player?.pause() }
                else { model.player?.play() }
            } label: { Image(systemName: "playpause.fill") }
            Spacer()
            Text(String(format: "%.1fs", model.duration)).font(.caption.monospacedDigit())
        }.buttonStyle(.plain).foregroundStyle(.white)
    }

    var editingArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                LibraryVideoButton(model: model)
                Button { importing = true } label: { Label("Tệp", systemImage: "folder") }
                Button { Task { await model.export() } } label: { Label("Xuất MP4", systemImage: "square.and.arrow.up") }
                    .disabled(model.clips.isEmpty || model.busy)
                if let url = model.exportedURL {
                    ShareLink(item: url) { Image(systemName: "square.and.arrow.up.on.square") }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.cyan)
            HStack {
                Text("TIMELINE · VIDEO").font(.caption.bold()).foregroundStyle(.gray)
                Spacer()
                Image(systemName: "minus.magnifyingglass")
                Slider(value: $zoom, in: 3...32).frame(maxWidth: 140)
                Image(systemName: "plus.magnifyingglass")
            }
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(model.clips) { clip in
                        Button {
                            model.selected = clip.id
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Image(systemName: "film").font(.title2)
                                Text(clip.url.deletingPathExtension().lastPathComponent.prefix(13))
                                    .font(.caption2).lineLimit(1)
                                Text(String(format: "%.1f s", clip.duration)).font(.caption2)
                            }
                            .foregroundStyle(.white)
                            .padding(8)
                            .frame(width: max(85, clip.duration * zoom), height: 91, alignment: .leading)
                            .background(model.selected == clip.id ? Color.blue : Color(red: 0.17, green: 0.21, blue: 0.34))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 105)
            if let clip = active {
                HStack {
                    Text("Đoạn đã chọn: \(String(format: "%.1fs", clip.duration))").font(.caption)
                    Spacer()
                    Button("Cắt đầu −1s") { model.trim(clip.id, side: "start", seconds: 1) }
                    Button("Cắt cuối −1s") { model.trim(clip.id, side: "end", seconds: -1) }
                }.font(.caption2).buttonStyle(.bordered)
            }
            HStack(spacing: 14) {
                Image(systemName: "waveform").foregroundStyle(.green)
                Text("A1 · Âm thanh nguồn").font(.caption).foregroundStyle(.gray)
                Spacer()
                Text("Cắt · Ghép · Sắp xếp").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(height: 34)
            .padding(.horizontal, 8)
            .background(.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            if model.busy { ProgressView().tint(.cyan) }
            if !model.progress.isEmpty { Text(model.progress).font(.caption).foregroundStyle(.gray).lineLimit(2) }
            Spacer(minLength: 0)
            if !model.clips.isEmpty {
                List {
                    ForEach(model.clips) { clip in
                        HStack {
                            Image(systemName: "film")
                            Text(clip.url.lastPathComponent).lineLimit(1)
                            Spacer()
                            Text(String(format: "%.1fs", clip.duration)).font(.caption)
                        }
                        .listRowBackground(Color.clear)
                    }
                    .onMove(perform: model.move)
                    .onDelete(perform: model.delete)
                }
                .listStyle(.plain)
                .frame(maxHeight: 110)
            }
        }
    }
}

import AVKit
struct VideoPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = true
        return vc
    }
    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player { vc.player = player }
    }
}
