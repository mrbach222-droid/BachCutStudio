import Foundation

struct VideoSegment: Identifiable, Codable, Equatable {
    var id = UUID()
    var url: URL
    var start: Double
    var end: Double
    var sourceDuration: Double = 0
    var speed: Double = 1
    var volume: Double = 1
    var duration: Double { max(0, end - start) / max(0.25, speed) }
    enum CodingKeys: String, CodingKey { case id, url, start, end, sourceDuration, speed, volume }
    init(id: UUID = UUID(), url: URL, start: Double, end: Double, sourceDuration: Double = 0, speed: Double = 1, volume: Double = 1) {
        self.id = id; self.url = url; self.start = start; self.end = end
        self.sourceDuration = sourceDuration > 0 ? sourceDuration : end
        self.speed = speed; self.volume = volume
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); url = try c.decode(URL.self, forKey: .url)
        start = try c.decode(Double.self, forKey: .start); end = try c.decode(Double.self, forKey: .end)
        sourceDuration = try c.decodeIfPresent(Double.self, forKey: .sourceDuration) ?? end
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
    }
    mutating func normalize() {
        sourceDuration = sourceDuration.isFinite ? max(0, sourceDuration) : 0
        start = start.isFinite ? min(max(0, start), sourceDuration) : 0
        end = end.isFinite ? min(max(start, end), sourceDuration) : sourceDuration
        speed = speed.isFinite ? min(4, max(0.25, speed)) : 1
        volume = volume.isFinite ? min(1, max(0, volume)) : 1
    }
}
struct AudioSegment: Identifiable, Codable, Equatable {
    var id = UUID()
    var url: URL
    var offset: Double = 0
    var sourceDuration: Double
    var volume: Double = 0.7
    // nil means the entire original audio file, preserving older saved projects.
    var trimDuration: Double? = nil
    var duration: Double { max(0, min(sourceDuration, trimDuration ?? sourceDuration)) }
}
struct OverlaySegment: Identifiable, Codable, Equatable {
    var id = UUID()
    var clip: VideoSegment
    var offset: Double = 0
}
enum CanvasRatio: String, Codable, CaseIterable {
    case original, portrait, landscape, square
    var label: String {
        switch self { case .original: return "Gốc"; case .portrait: return "9:16"; case .landscape: return "16:9"; case .square: return "1:1" }
    }
}
struct StudioProject: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = "Dự án mới"
    var clips: [VideoSegment] = []
    var audio: [AudioSegment] = []
    var overlays: [OverlaySegment] = []
    var ratio: CanvasRatio = .original
    var modified = Date()
    var duration: Double { clips.reduce(0) { $0 + $1.duration } }
    var mediaURLs: [URL] { clips.map(\.url) + audio.map(\.url) + overlays.map { $0.clip.url } }
    func startTime(of id: UUID) -> Double {
        var time = 0.0
        for clip in clips { if clip.id == id { return time }; time += clip.duration }
        return time
    }
    mutating func split(id: UUID, at time: Double) -> UUID? {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return nil }
        let position = time - startTime(of: id)
        guard position > 0.05, position < clips[i].duration - 0.05 else { return nil }
        var right = clips[i]
        let sourcePosition = right.start + position * right.speed
        right.id = UUID(); right.start = sourcePosition
        clips[i].end = sourcePosition
        clips.insert(right, at: i + 1)
        return right.id
    }
    mutating func duplicate(id: UUID) -> UUID? {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return nil }
        var copy = clips[i]; copy.id = UUID()
        clips.insert(copy, at: i + 1); return copy.id
    }
}

struct ProjectStore {
    let root: URL
    init(root: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]) { self.root = root }
    var mediaDirectory: URL { root.appendingPathComponent("Media", isDirectory: true) }
    var projectsDirectory: URL { root.appendingPathComponent("Projects", isDirectory: true) }
    func prepare() throws {
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
    }
    func save(_ project: StudioProject) throws {
        try prepare()
        var portable = project
        for i in portable.clips.indices { portable.clips[i].url = portableURL(portable.clips[i].url) }
        for i in portable.audio.indices { portable.audio[i].url = portableURL(portable.audio[i].url) }
        for i in portable.overlays.indices { portable.overlays[i].clip.url = portableURL(portable.overlays[i].clip.url) }
        try JSONEncoder().encode(portable).write(to: projectsDirectory.appendingPathComponent(project.id.uuidString + ".json"), options: .atomic)
    }
    private func portableURL(_ url: URL) -> URL { URL(string: "media://local/" + url.lastPathComponent)! }
    private func localURL(_ url: URL) -> URL { mediaDirectory.appendingPathComponent(url.lastPathComponent) }
    func load(_ url: URL) throws -> StudioProject {
        var p = try JSONDecoder().decode(StudioProject.self, from: Data(contentsOf: url))
        for i in p.clips.indices { p.clips[i].url = localURL(p.clips[i].url); p.clips[i].normalize() }
        for i in p.audio.indices { p.audio[i].url = localURL(p.audio[i].url) }
        for i in p.overlays.indices { p.overlays[i].clip.url = localURL(p.overlays[i].clip.url); p.overlays[i].clip.normalize() }
        return p
    }
    func list() throws -> [StudioProject] {
        try prepare()
        return try FileManager.default.contentsOfDirectory(at: projectsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try load($0) }.sorted { $0.modified > $1.modified }
    }
    func migrateLegacy() throws {
        let url = root.appendingPathComponent("bachcut-project.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        struct Legacy: Decodable { var name: String; var clips: [VideoSegment] }
        let old = try JSONDecoder().decode(Legacy.self, from: Data(contentsOf: url))
        var p = StudioProject(); p.name = old.name; p.clips = old.clips
        for i in p.clips.indices { p.clips[i].url = localURL(p.clips[i].url) }
        try save(p)
        try FileManager.default.moveItem(at: url, to: root.appendingPathComponent("bachcut-project.migrated"))
    }
    func delete(_ project: StudioProject) throws {
        try FileManager.default.removeItem(at: projectsDirectory.appendingPathComponent(project.id.uuidString + ".json"))
        // Media may still be referenced by another project or undo history. Keep it safely.
    }
}
