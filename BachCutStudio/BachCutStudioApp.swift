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
    @Environment(\.verticalSizeClass) private var verticalClass
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false
    @State private var importKind: EditorModel.ImportKind = .video
    @State private var zoom = 24.0
    @State private var showTrim = false
    @State private var showExport = false
    @State private var editingTrack: TrackTimingSelection?
    init(project: StudioProject, store: ProjectStore = ProjectStore()) { _model = StateObject(wrappedValue: EditorModel(project: project, store: store)) }
    var body: some View {
        GeometryReader { geo in
            let wide = verticalClass == .compact
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
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button { model.saveProject(); model.close(); dismiss() } label: { Label("Quay lại", systemImage: "chevron.left").labelStyle(.iconOnly) }.accessibilityIdentifier("backEditor")
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button("Lưu") { if model.saveProject() { model.progress = "Đã lưu dự án" } }.accessibilityIdentifier("saveProject")
                Button("Xuất") { model.pause(); showExport = true }
                    .disabled(model.clips.isEmpty || model.rendering || model.busy).accessibilityIdentifier("exportVideo")
            }
        }
        .task { await model.start() }
        .onDisappear { model.saveProject(); model.pause() }
        .onChange(of: phase) { if $0 != .active { model.saveProject(); model.pause() } }
        .fileImporter(isPresented: $importing, allowedContentTypes: importKind == .audio ? [.audio] : [.movie, .video], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { for url in urls { await model.add(url: url, kind: importKind) } }
            case .failure(let error): model.progress = error.localizedDescription
            }
        }
        .sheet(isPresented: $showTrim) { if let clip = model.selectedClip { TrimSheet(clip: clip) { start, end in model.trim(clip.id, start: start, end: end) } } }
        .sheet(isPresented: $showExport) { ExportSheet(model: model) }
        .sheet(item: $editingTrack) { track in
            if track.kind == .audio, let sound = model.project.audio.first(where: { $0.id == track.id }) {
                TrackTimingSheet(title: "Nhạc nền", offset: sound.offset, length: sound.duration,
                                 maxLength: sound.sourceDuration, timelineLength: model.duration, playhead: model.playhead) { start, length in
                    model.setAudioTiming(sound.id, offset: start, duration: length)
                }
            } else if track.kind == .overlay, let overlay = model.project.overlays.first(where: { $0.id == track.id }) {
                TrackTimingSheet(title: "Lớp phủ video", offset: overlay.offset, length: overlay.clip.duration,
                                 maxLength: (overlay.clip.sourceDuration - overlay.clip.start) / overlay.clip.speed,
                                 timelineLength: model.duration, playhead: model.playhead) { start, length in
                    model.setOverlayTiming(overlay.id, offset: start, duration: length)
                }
            }
        }
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
        }.accessibilityElement(children: .contain).accessibilityIdentifier("videoPreview")
    }
    var transport: some View {
        VStack(spacing: 10) {
            HStack {
                Text(formatTime(model.playhead)).font(.caption.monospacedDigit()).accessibilityIdentifier("playheadTime")
                Spacer()
                Button { model.seek(0) } label: { Image(systemName: "backward.end.fill") }.accessibilityLabel("Về đầu")
                Button { model.togglePlayback() } label: { Image(systemName: model.playing ? "pause.fill" : "play.fill").frame(width: 44, height: 44).contentShape(Rectangle()) }
                    .disabled(!model.playerReady || model.rendering || model.busy).accessibilityIdentifier("playPause").accessibilityLabel(model.playing ? "Tạm dừng" : "Phát")
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
            }.font(.caption.bold()).buttonStyle(.bordered).disabled(model.busy)
        }.padding(.vertical, 5)
    }
    var timeline: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("TIMELINE").font(.caption.bold()).foregroundStyle(.gray)
                Spacer(); Image(systemName: "minus.magnifyingglass")
                Slider(value: $zoom, in: 8...80).frame(width: 110).accessibilityIdentifier("timelineZoom")
                Image(systemName: "plus.magnifyingglass")
            }.font(.caption)
            CenteredTimeline(project: model.project, selected: model.selected, thumbnails: model.thumbnails, zoom: zoom, playhead: model.playhead,
                             enabled: !model.busy && !model.rendering, select: model.select, beginScrub: model.beginScrub,
                             scrub: model.seek, endScrub: model.endScrub, changeZoom: { zoom = $0 },
                             beginMove: { id in model.pause(); model.selected = id }, move: model.moveClip,
                             tapTrack: { id, isOverlay in
                                 editingTrack = TrackTimingSelection(id: id, kind: isOverlay ? .overlay : .audio)
                             },
                             beginTrackDrag: { model.pause() },
                             moveTrack: { id, isOverlay, offset in
                                 if isOverlay { model.moveOverlayTrack(id, to: offset) }
                                 else { model.moveAudioTrack(id, to: offset) }
                             })
                .frame(height: CGFloat(128 + (model.project.overlays.count + model.project.audio.count) * 32))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text("Kéo tua · 2 ngón zoom · Nhấn giữ đổi clip · Kéo khối nhạc/lớp phủ để di chuyển").font(.caption2).foregroundStyle(.secondary)
            if !model.project.audio.isEmpty || !model.project.overlays.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(model.project.overlays) { overlay in
                            Menu("V2 · \(formatTime(overlay.offset)) · \(formatTime(overlay.clip.duration))") {
                                Button("Đổi vị trí và độ dài") { editingTrack = TrackTimingSelection(id: overlay.id, kind: .overlay) }
                                Button("Xóa lớp phủ", role: .destructive) { model.removeOverlay(overlay.id) }
                            }
                        }
                        ForEach(model.project.audio) { sound in
                            Menu("A2 · \(formatTime(sound.offset)) · \(formatTime(sound.duration))") {
                                Button("Đổi vị trí và độ dài") { editingTrack = TrackTimingSelection(id: sound.id, kind: .audio) }
                                Button("Âm lượng 50%") { model.audioVolume(sound.id, value: 0.5) }
                                Button("Âm lượng 100%") { model.audioVolume(sound.id, value: 1) }
                                Button("Xóa nhạc", role: .destructive) { model.removeAudio(sound.id) }
                            }
                        }
                    }.font(.caption).buttonStyle(.bordered)
                }
            }
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
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--uitesting") { Text(model.debugInfo).font(.system(size: 8)).accessibilityIdentifier("playerDebug") }
            #endif
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
struct TrackTimingSelection: Identifiable {
    enum Kind: Equatable { case audio, overlay }
    let id: UUID
    let kind: Kind
}

struct TrackTimingSheet: View {
    let title: String
    let maxLength: Double
    let timelineLength: Double
    let playhead: Double
    let apply: (Double, Double) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var offset: Double
    @State private var length: Double
    init(title: String, offset: Double, length: Double, maxLength: Double, timelineLength: Double,
         playhead: Double, apply: @escaping (Double, Double) -> Void) {
        self.title = title
        self.maxLength = maxLength
        self.timelineLength = timelineLength
        self.playhead = playhead
        self.apply = apply
        let start = min(max(0, offset), max(0, timelineLength - 0.05))
        _offset = State(initialValue: start)
        _length = State(initialValue: min(max(0.05, length), max(0.05, min(maxLength, timelineLength - start))))
    }
    private var maxOffset: Double { max(0, timelineLength - 0.05) }
    private var availableLength: Double { max(0.05, min(maxLength, timelineLength - offset)) }
    private func clampLength() { length = min(length, availableLength) }
    var body: some View {
        NavigationStack {
            Form {
                Section("Bắt đầu · " + formatTime(offset)) {
                    Slider(value: $offset, in: 0...max(0.001, maxOffset))
                        .accessibilityIdentifier("trackStart")
                    HStack {
                        Button("−0,1 giây") { offset = max(0, offset - 0.1); clampLength() }
                        Spacer()
                        Button("Tại vạch tua") { offset = min(maxOffset, max(0, playhead)); clampLength() }
                        Spacer()
                        Button("+0,1 giây") { offset = min(maxOffset, offset + 0.1); clampLength() }
                    }.font(.caption)
                }
                Section("Độ dài · " + formatTime(length)) {
                    Slider(value: $length, in: 0.05...availableLength)
                        .accessibilityIdentifier("trackDuration")
                    Text("Tối đa " + formatTime(availableLength) + " tại vị trí hiện tại.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .onChange(of: offset) { _ in clampLength() }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Hủy") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Áp dụng") { apply(offset, length); dismiss() }.accessibilityIdentifier("applyTrackTiming")
                }
            }
        }.presentationDetents([.medium, .large])
    }
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
final class PlayerSurface: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var videoLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
struct VideoPlayerView: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerSurface {
        let view = PlayerSurface()
        view.backgroundColor = .black; view.isUserInteractionEnabled = false
        view.videoLayer.videoGravity = .resizeAspect; view.videoLayer.player = player
        return view
    }
    func updateUIView(_ view: PlayerSurface, context: Context) { if view.videoLayer.player !== player { view.videoLayer.player = player } }
    static func dismantleUIView(_ view: PlayerSurface, coordinator: ()) { view.videoLayer.player = nil }
}
