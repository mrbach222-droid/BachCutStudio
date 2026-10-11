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
    @Published var exportFraction = 0.0
    private var exportTask: Task<Void, Never>?
    private var activeExport: UUID?
    @Published var selected: UUID?
    @Published var playhead = 0.0
    @Published var playing = false
    @Published var playerReady = false
    @Published var thumbnails: [UUID: [UIImage]] = [:]
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
    private var scrubbing = false
    private var pendingSeek: Double?
    private var seekOperation: UUID?
    private var previewURL: URL?
    private var thumbnailSources: [UUID: VideoSegment] = [:]
    #if DEBUG
    private var lastEvent = "init"
    var debugInfo: String { "ready=\(playerReady) rendering=\(rendering) busy=\(busy) rate=\(player?.rate ?? -1) control=\(player?.timeControlStatus.rawValue ?? -1) wait=\(player?.reasonForWaitingToPlay?.rawValue ?? "none") status=\(player?.currentItem?.status.rawValue ?? -1) time=\(player?.currentTime().seconds ?? -1) event=\(lastEvent) observer=\(observer != nil) same=\(observedPlayer === player) duration=\(player?.currentItem?.duration.seconds ?? -1)" }
    #endif
    private func recordEvent(_ event: String) {
        #if DEBUG
        lastEvent = event
        #endif
    }
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
    deinit {
        if let observer { observedPlayer?.removeTimeObserver(observer) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        statusObserver?.invalidate(); rebuildTask?.cancel()
        if let previewURL { try? FileManager.default.removeItem(at: previewURL) }
    }
    func close() { recordEvent("close"); player?.pause(); playing = false; detachObserver(); rebuildTask?.cancel(); exportTask?.cancel(); player = nil; discardPreviewFile() }
    private func discardPreviewFile() {
        if let previewURL { try? FileManager.default.removeItem(at: previewURL) }; previewURL = nil
    }
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
    func moveClip(_ id: UUID, to index: Int) {
        guard let from = clips.firstIndex(where: { $0.id == id }), clips.indices.contains(index), from != index else { return }
        pause()
        edit { p in let clip = p.clips.remove(at: from); p.clips.insert(clip, at: index) }
        // Keep the center playhead stable after a drag/drop rather than jumping
        // to the moved clip's new starting time.
        selected = id
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

    // Commit drag/slider edits once (on Apply), preserving one clean undo step.
    // Offsets are relative to the project's playhead and trimmed lengths never
    // exceed the underlying media or the available base-video timeline.
    func setAudioTiming(_ id: UUID, offset: Double, duration: Double) {
        guard offset.isFinite, duration.isFinite else { return }
        edit { project in
            guard let index = project.audio.firstIndex(where: { $0.id == id }), project.duration >= 0.05 else { return }
            let start = min(max(0, offset), max(0, project.duration - 0.05))
            let available = min(project.audio[index].sourceDuration, project.duration - start)
            guard available >= 0.05 else { return }
            project.audio[index].offset = start
            project.audio[index].trimDuration = min(available, max(0.05, duration))
        }
    }
    func setOverlayTiming(_ id: UUID, offset: Double, duration: Double) {
        guard offset.isFinite, duration.isFinite else { return }
        edit { project in
            guard let index = project.overlays.firstIndex(where: { $0.id == id }), project.duration >= 0.05 else { return }
            let start = min(max(0, offset), max(0, project.duration - 0.05))
            var clip = project.overlays[index].clip
            let available = min((clip.sourceDuration - clip.start) / clip.speed, project.duration - start)
            guard available >= 0.05 else { return }
            clip.end = min(clip.sourceDuration, clip.start + min(available, max(0.05, duration)) * clip.speed)
            clip.normalize()
            project.overlays[index].offset = start
            project.overlays[index].clip = clip
        }
    }
    func beginScrub() { pause(); scrubbing = true }
    func endScrub(_ value: Double) { scrubbing = false; seek(value) }
    func seek(_ value: Double) {
        guard value.isFinite else { return }
        recordEvent("seek")
        playhead = min(duration, max(0, value)); seekRevision += 1
        pendingSeek = playhead
        chaseSeek()
    }
    // Keep one native seek in flight and retain only the latest requested position.
    private func chaseSeek() {
        guard seekOperation == nil, !rendering, let value = pendingSeek, let player else { return }
        pendingSeek = nil
        let token = UUID(); seekOperation = token
        let tolerance = scrubbing ? CMTime(value: 1, timescale: 30) : .zero
        player.seek(to: MediaComposer.time(value), toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self, weak player] _ in
            Task { @MainActor in
                guard let self, self.seekOperation == token, self.player === player else { return }
                self.seekOperation = nil; self.chaseSeek()
            }
        }
    }
    func togglePlayback() {
        recordEvent("toggle")
        guard !rendering, !busy, playerReady, let player else { return }
        playbackRevision += 1
        if playing { player.pause(); playing = false } else {
            if playhead >= duration - 0.05 { seek(0) }; player.playImmediately(atRate: 1); playing = true
        }
    }
    func pause() { recordEvent("pause"); playbackRevision += 1; player?.pause(); playing = false }
    func refreshPreview() async {
        recordEvent("rebuild")
        let token = revision, snapshot = project
        let oldTime = playhead, oldSeek = seekRevision, shouldResume = playing, oldPlayback = playbackRevision
        seekOperation = nil; pendingSeek = nil; player?.currentItem?.cancelPendingSeeks()
        player?.pause() // Freeze the exact position while a replacement preview is prepared.
        rendering = true; playerReady = false
        defer { if token == revision { rendering = false } }
        do {
            if snapshot.clips.isEmpty { detachObserver(); player?.pause(); player = nil; discardPreviewFile(); playing = false; return }
            let rendered = try await MediaComposer.build(snapshot)
            guard token == revision, !Task.isCancelled else { return }
            let source = try await MediaComposer.previewSource(rendered, directory: FileManager.default.temporaryDirectory.appendingPathComponent("BachCutPreview", isDirectory: true))
            guard token == revision, !Task.isCancelled else {
                if let url = source.temporaryURL { try? FileManager.default.removeItem(at: url) }; return
            }
            let item = source.item
            let next = AVPlayer(playerItem: item)
            next.automaticallyWaitsToMinimizeStalling = false
            detachObserver(); player?.pause(); player = nil; discardPreviewFile(); previewURL = source.temporaryURL; player = next
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
                    if next.rate > 0 && value.isFinite && !self.scrubbing && self.seekOperation == nil && self.pendingSeek == nil { self.playhead = min(self.duration, max(0, value)) }
                    self.playing = next.rate > 0
                }
            }
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.playing = false; if let self { self.playhead = self.duration } }
            }
            let position = oldSeek == seekRevision ? oldTime : playhead
            await next.seek(to: MediaComposer.time(min(position, duration)), toleranceBefore: .zero, toleranceAfter: .zero)
            guard token == revision, !Task.isCancelled, player === next else { return }
            pendingSeek = nil
            if shouldResume && oldPlayback == playbackRevision { next.playImmediately(atRate: 1); playing = true }
        } catch {
            guard token == revision else { return }
            pause(); detachObserver(); player = nil; discardPreviewFile(); progress = "Không xem trước được: " + error.localizedDescription
        }
    }
    func loadThumbnails() async {
        let segments = clips + project.overlays.map(\.clip)
        let activeIDs = Set(segments.map(\.id))
        thumbnails = thumbnails.filter { activeIDs.contains($0.key) }
        thumbnailSources = thumbnailSources.filter { activeIDs.contains($0.key) }
        for clip in segments where thumbnails[clip.id] == nil || (thumbnailSources[clip.id].map { $0.url != clip.url || $0.start != clip.start || $0.end != clip.end || $0.speed != clip.speed } ?? true) {
            if Task.isCancelled { return }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: clip.url))
            generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 128, height: 96)
            // Neighboring frames can share a keyframe. Only the final scrub uses an exact seek.
            generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 4)
            generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 4)
            let count = min(20, max(1, Int(ceil(clip.duration / 1.25))))
            var frames: [UIImage] = []
            for index in 0..<count {
                if Task.isCancelled { return }
                let sourceTime = clip.start + (Double(index) + 0.5) / Double(count) * (clip.end - clip.start)
                do {
                    let (cgImage, _) = try await generator.image(at: MediaComposer.time(sourceTime))
                    frames.append(UIImage(cgImage: cgImage))
                } catch { break /* Missing media is reported by preview. */ }
            }
            guard !Task.isCancelled else { return }
            let current = clips + project.overlays.map(\.clip)
            if !frames.isEmpty, current.contains(where: { $0.id == clip.id && $0.url == clip.url && $0.start == clip.start && $0.end == clip.end && $0.speed == clip.speed }) {
                thumbnails[clip.id] = frames; thumbnailSources[clip.id] = clip
            }
        }
    }
    func startExport(options: ExportOptions) { guard !busy else { return }; exportTask = Task { await export(options: options) } }
    func cancelExport() { exportTask?.cancel() }
    func export(options: ExportOptions? = nil) async {
        guard !busy, !rendering, !clips.isEmpty else { return }
        let format = options?.format ?? .mp4
        let exportID = UUID(); activeExport = exportID
        busy = true; pause(); exportFraction = 0; progress = "Đang xuất " + format.rawValue + "…"; exportedURL = nil
        defer { busy = false }
        do {
            let rendered = try await MediaComposer.build(project, options: options)
            let directory = store.root.appendingPathComponent("Exports", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("BachCut-" + UUID().uuidString + "." + format.fileExtension)
            if let options {
                try await ConfiguredExporter.export(rendered, options: options, to: url) { [weak self] value in
                    Task { @MainActor in if let self, self.activeExport == exportID, self.busy { self.exportFraction = max(self.exportFraction, value) } }
                }
            } else { try await MediaComposer.export(rendered, to: url) }
            exportedURL = url; exportFraction = 1; progress = "Đã xuất " + format.rawValue + " thành công"
        } catch is CancellationError { progress = "Đã hủy xuất" }
        catch { progress = "Xuất thất bại: " + error.localizedDescription }
    }
    func saveToPhotos() async {
        guard !busy, let url = exportedURL else { return }
        busy = true; defer { busy = false }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { progress = "Cho phép thêm video vào Ảnh trong Cài đặt"; return }
        do {
            try await PHPhotoLibrary.shared().performChanges { if url.pathExtension.lowercased() == "gif" { PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url) }
                else { PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url) } }
            progress = "Đã lưu video vào Ảnh"
        } catch { progress = "Không lưu được vào Ảnh: " + error.localizedDescription }
    }
}
