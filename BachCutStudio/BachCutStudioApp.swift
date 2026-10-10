import SwiftUI
import AVKit
import UniformTypeIdentifiers

@main struct BachCutStudioApp: App {
    init() { try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback) }
    var body: some Scene { WindowGroup { StudioHome().preferredColorScheme(.dark) } }
}
struct EditorScreen: View {
    @StateObject var model: EditorModel
    @Environment(\.scenePhase) private var phase
    @State private var importing = false
    @State private var importKind: EditorModel.ImportKind = .video
    @State private var zoom = 24.0
    @State private var showTrim = false
    init(project: StudioProject, store: ProjectStore = ProjectStore()) { _model = StateObject(wrappedValue: EditorModel(project: project, store: store)) }
    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > geo.size.height
            VStack(spacing: 8) {
                header
                if wide {
                    HStack(spacing: 12) {
                        VStack { preview; transport }.frame(width: geo.size.width * 0.34)
                        ScrollView { controls; timeline; tools; messages }.frame(maxWidth: .infinity)
                    }
                } else {
                    preview.frame(height: min(geo.size.height * 0.31, 270))
                    transport
                    ScrollView { controls; timeline; tools; messages }
                }
            }.padding(10).background(Color(red: 0.04, green: 0.05, blue: 0.075))
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle("Studio")
        .toolbar { ToolbarItem(placement: .navigationBarTrailing) { Button("Lưu") { model.saveProject(); model.progress = "Đã lưu dự án" }.accessibilityIdentifier("saveProject") } }
        .task { await model.start() }
        .onDisappear { model.saveProject(); model.close() }
        .onChange(of: phase) { if $0 != .active { model.saveProject(); model.pause() } }
        .fileImporter(isPresented: $importing, allowedContentTypes: importKind == .audio ? [.audio] : [.movie, .video], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { for url in urls { await model.add(url: url, kind: importKind) } }
            case .failure(let error): model.progress = error.localizedDescription
            }
        }
        .sheet(isPresented: $showTrim) { if let clip = model.selectedClip { TrimSheet(clip: clip) { start, end in model.trim(clip.id, start: start, end: end) } } }
        .tint(.cyan)
    }
    var header: some View {
        HStack {
            TextField("Tên dự án", text: Binding(get: { model.project.name }, set: { model.rename($0) }))
                .font(.headline).accessibilityIdentifier("projectName")
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(model.undoStack.isEmpty || model.busy).accessibilityIdentifier("undo")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(model.redoStack.isEmpty || model.busy).accessibilityIdentifier("redo")
            Menu { ForEach(CanvasRatio.allCases, id: \.self) { ratio in Button(ratio.label) { model.setRatio(ratio) } } } label: { Text(model.project.ratio.label).font(.caption.bold()) }
        }.padding(.horizontal, 4)
    }
    var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(.black)
            if let player = model.player { VideoPlayerView(player: player).clipShape(RoundedRectangle(cornerRadius: 14)) }
            else { VStack(spacing: 8) { Image(systemName: "film.stack").font(.largeTitle); Text("Thêm video để bắt đầu").font(.subheadline) }.foregroundStyle(.gray) }
            if model.rendering { ProgressView().padding(12).background(.ultraThinMaterial).clipShape(Circle()) }
        }.accessibilityIdentifier("videoPreview")
    }
    var transport: some View {
        VStack(spacing: 4) {
            HStack {
                Text(formatTime(model.playhead)).font(.caption.monospacedDigit()).accessibilityIdentifier("playheadTime")
                Spacer()
                Button { model.seek(0) } label: { Image(systemName: "backward.end.fill") }.accessibilityLabel("Về đầu")
                Button { model.togglePlayback() } label: { Image(systemName: model.playing ? "pause.fill" : "play.fill").frame(width: 36, height: 28) }
                    .disabled(!model.playerReady || model.rendering || model.busy).accessibilityIdentifier("playPause")
                Spacer()
                Text(formatTime(model.duration)).font(.caption.monospacedDigit()).accessibilityIdentifier("durationTime")
            }.foregroundStyle(.white).buttonStyle(.plain)
            Slider(value: Binding(get: { model.playhead }, set: { model.seek($0) }), in: 0...max(0.01, model.duration), onEditingChanged: { if $0 { model.pause() } })
                .disabled(model.clips.isEmpty || model.rendering || model.busy).accessibilityIdentifier("scrubber")
        }
    }
    var controls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                LibraryVideoButton(model: model)
                Button { importKind = .video; importing = true } label: { Label("Tệp", systemImage: "folder") }
                Button { importKind = .overlay; importing = true } label: { Label("Lớp phủ", systemImage: "square.on.square") }.disabled(model.clips.isEmpty)
                Button { importKind = .audio; importing = true } label: { Label("Nhạc", systemImage: "music.note") }.disabled(model.clips.isEmpty)
                Button { Task { await model.export() } } label: { Label("Xuất MP4", systemImage: "square.and.arrow.up") }
                    .disabled(model.clips.isEmpty || model.rendering).accessibilityIdentifier("exportVideo")
            }.font(.caption.bold()).buttonStyle(.bordered).disabled(model.busy)
        }.padding(.vertical, 5)
    }
    var timeline: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("TIMELINE").font(.caption.bold()).foregroundStyle(.gray)
                Spacer(); Image(systemName: "minus.magnifyingglass")
                Slider(value: $zoom, in: 8...80).frame(width: 110)
                Image(systemName: "plus.magnifyingglass")
            }.font(.caption)
            ScrollView(.horizontal) {
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 6) {
                        ruler
                        HStack(spacing: 0) {
                            ForEach(model.clips) { clip in
                                Button { model.select(clip.id) } label: {
                                    ZStack(alignment: .bottomLeading) {
                                        Color(red: 0.12, green: 0.22, blue: 0.28)
                                        if let image = model.thumbnails[clip.id] { Image(uiImage: image).resizable().scaledToFill() }
                                        Text(formatTime(clip.duration)).font(.caption2.monospacedDigit()).padding(4).background(.black.opacity(0.6))
                                    }.frame(width: max(1, clip.duration * zoom), height: 60).clipped()
                                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(model.selected == clip.id ? Color.cyan : Color.black, lineWidth: model.selected == clip.id ? 3 : 1))
                                }.buttonStyle(.plain).accessibilityIdentifier("clip_" + String(model.clips.firstIndex(where: { $0.id == clip.id }) ?? 0))
                            }
                        }
                        ForEach(model.project.overlays) { overlay in
                            timelineRow(label: "V2 · Lớp phủ", offset: overlay.offset, length: min(overlay.clip.duration, max(0, model.duration - overlay.offset)), color: .purple)
                                .contextMenu { Button("Xóa lớp phủ", role: .destructive) { model.removeOverlay(overlay.id) } }
                        }
                        timelineRow(label: "A1 · Âm thanh nguồn", offset: 0, length: model.duration, color: .teal)
                        ForEach(model.project.audio) { sound in
                            timelineRow(label: "A2 · Nhạc \(Int(sound.volume * 100))%", offset: sound.offset, length: min(sound.sourceDuration, max(0, model.duration - sound.offset)), color: .green)
                                .contextMenu {
                                    Button("Âm lượng 50%") { model.audioVolume(sound.id, value: 0.5) }
                                    Button("Âm lượng 100%") { model.audioVolume(sound.id, value: 1) }
                                    Button("Xóa nhạc", role: .destructive) { model.removeAudio(sound.id) }
                                }
                        }
                    }.frame(width: max(240, model.duration * zoom), alignment: .leading)
                    Rectangle().fill(.white).frame(width: 2).offset(x: model.playhead * zoom).allowsHitTesting(false)
                }.padding(.vertical, 3)
            }.frame(minHeight: 125).background(.white.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
    var ruler: some View {
        ZStack(alignment: .leading) {
            Color.clear.frame(height: 22)
            let step = max(max(1, Int(80 / zoom)), Int(ceil(model.duration / 300)))
            ForEach(Array(stride(from: 0, through: Int(ceil(model.duration)), by: step)), id: \.self) { second in
                Text(formatTime(Double(second))).font(.system(size: 9, design: .monospaced)).foregroundStyle(.gray).offset(x: Double(second) * zoom)
            }
        }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onEnded { value in
            model.pause(); model.seek(value.location.x / zoom)
        })
    }
    func timelineRow(label: String, offset: Double, length: Double, color: Color) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: max(0, offset) * zoom, height: 26)
            Text(label).font(.caption2).lineLimit(1).padding(.horizontal, 5).frame(width: max(1, length * zoom), height: 26, alignment: .leading).background(color.opacity(0.25)).clipped()
        }
    }
    var tools: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let clip = model.selectedClip {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button { showTrim = true } label: { Label("Cắt", systemImage: "crop") }.accessibilityIdentifier("trimClip")
                        Button { model.splitSelected() } label: { Label("Tách", systemImage: "scissors") }.accessibilityIdentifier("splitClip")
                        Button { model.duplicateSelected() } label: { Label("Nhân đôi", systemImage: "plus.square.on.square") }.accessibilityIdentifier("duplicateClip")
                        Button { model.moveSelected(-1) } label: { Image(systemName: "arrow.left") }.accessibilityLabel("Chuyển trước")
                        Button { model.moveSelected(1) } label: { Image(systemName: "arrow.right") }.accessibilityLabel("Chuyển sau")
                        Button(role: .destructive) { model.removeSelected() } label: { Label("Xóa", systemImage: "trash") }.accessibilityIdentifier("deleteClip")
                    }.buttonStyle(.bordered).font(.caption)
                }
                HStack {
                    Menu { ForEach([0.5, 1.0, 1.5, 2.0, 4.0], id: \.self) { speed in Button("\(speed, specifier: "%.1f")×") { model.setSpeed(speed) } } } label: { Label("\(clip.speed, specifier: "%.1f")×", systemImage: "speedometer") }
                    Menu { ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { value in Button("\(Int(value * 100))%") { model.setVolume(value) } } } label: { Label("\(Int(clip.volume * 100))%", systemImage: clip.volume == 0 ? "speaker.slash" : "speaker.wave.2") }
                    Spacer(); Text("\(model.clips.count) đoạn").font(.caption).foregroundStyle(.gray).accessibilityIdentifier("clipCount")
                }.font(.caption).padding(.horizontal, 3)
            }
        }.disabled(model.busy).padding(.vertical, 6)
    }
    var messages: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.busy { HStack { ProgressView(); Text(model.progress).font(.caption) } }
            else if !model.progress.isEmpty { Text(model.progress).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("statusMessage") }
            if let url = model.exportedURL {
                HStack {
                    ShareLink(item: url) { Label("Chia sẻ / Lưu Tệp", systemImage: "square.and.arrow.up") }
                    Button { Task { await model.saveToPhotos() } } label: { Label("Lưu vào Ảnh", systemImage: "photo") }
                }.font(.caption).buttonStyle(.bordered).disabled(model.busy)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
    }
}
func formatTime(_ value: Double) -> String {
    guard value.isFinite else { return "00:00.0" }; let safe = max(0, value)
    return String(format: "%02d:%04.1f", Int(safe) / 60, safe.truncatingRemainder(dividingBy: 60))
}
struct TrimSheet: View {
    let clip: VideoSegment
    let apply: (Double, Double) -> Void
    @Environment(\.dismiss) var dismiss
    @State var start: Double
    @State var end: Double
    init(clip: VideoSegment, apply: @escaping (Double, Double) -> Void) {
        self.clip = clip; self.apply = apply; _start = State(initialValue: clip.start); _end = State(initialValue: clip.end)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Điểm bắt đầu · " + formatTime(start)) { Slider(value: $start, in: 0...max(0.001, end - 0.05)) }
                Section("Điểm kết thúc · " + formatTime(end)) { Slider(value: $end, in: min(clip.sourceDuration, start + 0.05)...clip.sourceDuration) }
                Text("Đoạn còn lại: " + formatTime((end - start) / clip.speed))
            }.navigationTitle("Cắt chính xác").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Quay lại") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Áp dụng") { apply(start, end); dismiss() } }
            }
        }.presentationDetents([.medium, .large])
    }
}
struct VideoPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController { let vc = AVPlayerViewController(); vc.player = player; vc.showsPlaybackControls = false; return vc }
    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) { if vc.player !== player { vc.player = player } }
}
