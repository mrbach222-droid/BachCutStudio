import SwiftUI
import AVFoundation
import Photos

@MainActor final class EditorModel: ObservableObject {
    @Published private(set) var project: StudioProject
    @Published var player: AVPlayer?
    @Published var busy = false
    @Published var rendering = false
    @Published var progress = ""
    @Published var exportedURL: URL?
    @Published var selected: UUID?
    @Published var playhead = 0.0
    @Published var playing = false
    @Published var playerReady = false
    @Published var thumbnails: [UUID: UIImage] = [:]
    @Published private(set) var undoStack: [StudioProject] = []
    @Published private(set) var redoStack: [StudioProject] = []
    let store: ProjectStore
    private var revision = 0
    private var rebuildTask: Task<Void, Never>?
    private var observer: Any?
    private var observedPlayer: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var seekRevision = 0
    private var playbackRevision = 0
    private var thumbnailStarts: [UUID: Double] = [:]
    var clips: [VideoSegment] { project.clips }
    var duration: Double { project.duration }
    var selectedClip: VideoSegment? { clips.first { $0.id == selected } }
    init(project: StudioProject = StudioProject(), store: ProjectStore = ProjectStore()) {
        self.project = project; self.store = store; selected = project.clips.first?.id
    }
    func start() async {
        let missing = project.mediaURLs.filter { !FileManager.default.fileExists(atPath: $0.path) }
        if !missing.isEmpty { progress = "Thiếu \(missing.count) tệp nguồn. Dự án được giữ lại; hãy nhập lại tệp trước khi xuất." }
        await refreshPreview()
        await loadThumbnails()
    }
    func close() { player?.pause(); playing = false; detachObserver(); rebuildTask?.cancel() }
    private func detachObserver() {
        if let token = observer { observedPlayer?.removeTimeObserver(token) }
        if let token = endObserver { NotificationCenter.default.removeObserver(token) }
        statusObserver?.invalidate(); statusObserver = nil
        observer = nil; observedPlayer = nil; endObserver = nil
    }
    @discardableResult func saveProject() -> Bool {
        do { try store.save(project); return true } catch { progress = "Không lưu được dự án: " + error.localizedDescription; return false }
    }
    func rename(_ name: String) { project.name = name; project.modified = Date(); saveProject() }
    private func edit(_ mutation: (inout StudioProject) -> Void) {
        guard !busy else { return }
        let prior = project
        mutation(&project)
        guard project != prior else { return }
        undoStack.append(prior); if undoStack.count > 50 { undoStack.removeFirst() }; redoStack.removeAll()
        finishEdit()
    }
    private func finishEdit() {
        project.modified = Date()
        if !clips.contains(where: { $0.id == selected }) { selected = clips.first?.id }
        playhead = min(playhead, duration); exportedURL = nil
        saveProject(); revision += 1
        rebuildTask?.cancel()
        rebuildTask = Task { await refreshPreview(); await loadThumbnails() }
    }
    func undo() { guard !busy, let prior = undoStack.popLast() else { return }; redoStack.append(project); project = prior; finishEdit() }
    func redo() { guard !busy, let next = redoStack.popLast() else { return }; undoStack.append(project); project = next; finishEdit() }
    enum ImportKind { case video, audio, overlay }
    func add(url: URL, kind: ImportKind = .video) async {
        guard !busy else { return }
        busy = true; progress = "Đang nhập…"
        defer { busy = false }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        var copy: URL?
        do {
            try store.prepare()
            let destination = store.mediaDirectory.appendingPathComponent(UUID().uuidString + "." + (url.pathExtension.isEmpty ? "mov" : url.pathExtension))
            try await Task.detached(priority: .userInitiated) { try FileManager.default.copyItem(at: url, to: destination) }.value; copy = destination
            let asset = AVURLAsset(url: destination)
            let length = try await asset.load(.duration).seconds
            guard length.isFinite, length > 0.05 else { throw StudioError.message("Tệp quá ngắn hoặc không hợp lệ") }
            let mediaType: AVMediaType = kind == .audio ? .audio : .video
            guard !(try await asset.loadTracks(withMediaType: mediaType)).isEmpty else { throw StudioError.message(kind == .audio ? "Tệp không có âm thanh" : "Tệp không có video") }
            if kind == .overlay && clips.isEmpty { throw StudioError.message("Thêm video chính trước lớp phủ") }
            let prior = project
            let clip = VideoSegment(url: destination, start: 0, end: length, sourceDuration: length)
            switch kind {
            case .video: project.clips.append(clip); selected = clip.id
            case .audio: project.audio.append(AudioSegment(url: destination, offset: playhead, sourceDuration: length))
            case .overlay: project.overlays.append(OverlaySegment(clip: clip, offset: playhead))
            }
            undoStack.append(prior); if undoStack.count > 50 { undoStack.removeFirst() }; redoStack.removeAll(); finishEdit()
            progress = "Đã nhập và lưu dự án"
        } catch { if let copy { try? FileManager.default.removeItem(at: copy) }; progress = "Không nhập được: " + error.localizedDescription }
    }
    func select(_ id: UUID) { selected = id; seek(project.startTime(of: id)) }
    func trim(_ id: UUID, start: Double? = nil, end: Double? = nil) {
        edit { p in
            guard let i = p.clips.firstIndex(where: { $0.id == id }) else { return }
            if let start { p.clips[i].start = min(max(0, start), p.clips[i].end - min(0.05, p.clips[i].end)) }
            if let end { p.clips[i].end = max(p.clips[i].start + 0.05, min(p.clips[i].sourceDuration, end)) }
            p.clips[i].normalize()
        }
    }
    func setSpeed(_ value: Double) { guard let id = selected else { return }; edit { p in if let i = p.clips.firstIndex(where: { $0.id == id }) { p.clips[i].speed = value; p.clips[i].normalize() } } }
    func setVolume(_ value: Double) { guard let id = selected else { return }; edit { p in if let i = p.clips.firstIndex(where: { $0.id == id }) { p.clips[i].volume = value; p.clips[i].normalize() } } }
    func setRatio(_ ratio: CanvasRatio) { edit { $0.ratio = ratio } }
    func moveSelected(_ direction: Int) {
        guard let id = selected, let i = clips.firstIndex(where: { $0.id == id }), clips.indices.contains(i + direction) else { return }
        edit { $0.clips.swapAt(i, i + direction) }
    }
    func removeSelected() { guard let id = selected else { return }; edit { $0.clips.removeAll { $0.id == id } } }
    func duplicateSelected() { guard let id = selected else { return }; var newID: UUID?; edit { newID = $0.duplicate(id: id) }; selected = newID }
    func splitSelected() {
        guard let id = selected else { return }; var newID: UUID?
        edit { newID = $0.split(id: id, at: playhead) }
        if let newID { selected = newID } else { progress = "Đặt vạch tua vào bên trong đoạn đã chọn để tách" }
    }
    func removeAudio(_ id: UUID) { edit { $0.audio.removeAll { $0.id == id } } }
    func audioVolume(_ id: UUID, value: Double) { edit { p in if let i = p.audio.firstIndex(where: { $0.id == id }) { p.audio[i].volume = min(1, max(0, value)) } } }
    func removeOverlay(_ id: UUID) { edit { $0.overlays.removeAll { $0.id == id } } }
    func seek(_ value: Double) {
        playhead = min(duration, max(0, value)); seekRevision += 1
        player?.seek(to: MediaComposer.time(playhead), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    func togglePlayback() {
        guard !rendering, !busy, playerReady, let player else { return }
        playbackRevision += 1
        if playing { player.pause(); playing = false } else {
            if playhead >= duration - 0.05 { seek(0) }; player.play(); playing = true
        }
    }
    func pause() { playbackRevision += 1; player?.pause(); playing = false }
    func refreshPreview() async {
        let token = revision, snapshot = project
        let oldTime = playhead, oldSeek = seekRevision, shouldResume = playing, oldPlayback = playbackRevision
        rendering = true; playerReady = false
        defer { if token == revision { rendering = false } }
        do {
            if snapshot.clips.isEmpty { detachObserver(); player?.pause(); player = nil; playing = false; return }
            let rendered = try await MediaComposer.build(snapshot)
            guard token == revision, !Task.isCancelled else { return }
            let item = AVPlayerItem(asset: rendered.composition); item.videoComposition = rendered.video
            if !rendered.audio.inputParameters.isEmpty { item.audioMix = rendered.audio }
            let next = AVPlayer(playerItem: item)
            detachObserver(); player?.pause(); player = next
            observedPlayer = next
            statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor in
                    guard let self, self.player?.currentItem === item else { return }
                    self.playerReady = item.status == .readyToPlay
                    if item.status == .failed { self.pause(); self.progress = "Lỗi preview: " + (item.error?.localizedDescription ?? "Không đọc được video") }
                }
            }
            observer = next.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
                Task { @MainActor in
                    guard let self, self.player === next else { return }
                    let value = time.seconds
                    if value.isFinite { self.playhead = min(self.duration, max(0, value)) }
                    self.playing = next.rate > 0
                }
            }
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.playing = false }
            }
            let position = oldSeek == seekRevision ? oldTime : playhead
            await next.seek(to: MediaComposer.time(min(position, duration)), toleranceBefore: .zero, toleranceAfter: .zero)
            guard token == revision, !Task.isCancelled, player === next else { return }
            if shouldResume && oldPlayback == playbackRevision { next.play(); playing = true }
        } catch {
            guard token == revision else { return }
            pause(); detachObserver(); player = nil; progress = "Không xem trước được: " + error.localizedDescription
        }
    }
    func loadThumbnails() async {
        let segments = clips + project.overlays.map(\.clip)
        for clip in segments where thumbnails[clip.id] == nil || thumbnailStarts[clip.id] != clip.start {
            if Task.isCancelled { return }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: clip.url))
            generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 240, height: 160)
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            do {
                let (cgImage, _) = try await generator.image(at: MediaComposer.time(clip.start))
                guard !Task.isCancelled else { return }
                let current = clips + project.overlays.map(\.clip)
                if current.contains(where: { $0.id == clip.id && $0.start == clip.start && $0.url == clip.url }) {
                    thumbnails[clip.id] = UIImage(cgImage: cgImage); thumbnailStarts[clip.id] = clip.start
                }
            } catch { /* Missing media is reported by preview. */ }
        }
    }
    func export() async {
        guard !busy, !rendering, !clips.isEmpty else { return }
        busy = true; pause(); progress = "Đang xuất MP4…"; exportedURL = nil
        defer { busy = false }
        do {
            let rendered = try await MediaComposer.build(project)
            let directory = store.root.appendingPathComponent("Exports", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("BachCut-" + UUID().uuidString + ".mp4")
            try await MediaComposer.export(rendered, to: url)
            exportedURL = url; progress = "Đã xuất MP4 thành công"
        } catch { progress = "Xuất thất bại: " + error.localizedDescription }
    }
    func saveToPhotos() async {
        guard !busy, let url = exportedURL else { return }
        busy = true; defer { busy = false }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { progress = "Cho phép thêm video vào Ảnh trong Cài đặt"; return }
        do {
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url) }
            progress = "Đã lưu video vào Ảnh"
        } catch { progress = "Không lưu được vào Ảnh: " + error.localizedDescription }
    }
}
