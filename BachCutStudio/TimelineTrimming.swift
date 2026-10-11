import Foundation

enum TimelineItemKind: String, Hashable { case video, audio, overlay }
enum TimelineTrimEdge: String, Hashable { case start, end }

// All deltas are timeline seconds. Source timestamps also account for speed.
// Main clips ripple after a commit; secondary tracks keep their opposite edge fixed.
struct TimelineTrimSpan: Equatable {
    var offset: Double
    var sourceStart: Double
    var sourceEnd: Double
    var sourceDuration: Double
    var speed: Double
    var duration: Double { (sourceEnd - sourceStart) / speed }

    func adjusted(edge: TimelineTrimEdge, delta: Double, kind: TimelineItemKind,
                  timelineDuration: Double) -> TimelineTrimSpan? {
        guard [offset, sourceStart, sourceEnd, sourceDuration, speed, delta, timelineDuration].allSatisfy(\.isFinite),
              offset >= 0, sourceStart >= 0, sourceEnd <= sourceDuration,
              speed >= 0.25, speed <= 4, duration >= 0.05 - 0.000001 else { return nil }
        var result = self
        let minimum = min(0.05, duration) * speed
        switch edge {
        case .start:
            let lower = kind == .video ? 0 : max(0, sourceStart - offset * speed)
            result.sourceStart = min(sourceEnd - minimum, max(lower, sourceStart + delta * speed))
            if kind != .video { result.offset += (result.sourceStart - sourceStart) / speed }
        case .end:
            let upper = kind == .video ? sourceDuration : min(sourceDuration, sourceStart + max(0, timelineDuration - offset) * speed)
            guard upper >= sourceStart + minimum else { return nil }
            result.sourceEnd = min(upper, max(sourceStart + minimum, sourceEnd + delta * speed))
        }
        return result
    }
}

extension StudioProject {
    func trimSpan(id: UUID, kind: TimelineItemKind) -> TimelineTrimSpan? {
        switch kind {
        case .video:
            guard let clip = clips.first(where: { $0.id == id }) else { return nil }
            return TimelineTrimSpan(offset: startTime(of: id), sourceStart: clip.start, sourceEnd: clip.end,
                                    sourceDuration: clip.sourceDuration, speed: clip.speed)
        case .audio:
            guard let sound = audio.first(where: { $0.id == id }) else { return nil }
            let visibleLength = min(sound.duration, max(0, duration - sound.offset))
            return TimelineTrimSpan(offset: sound.offset, sourceStart: sound.sourceStart,
                                    sourceEnd: min(sound.sourceDuration, sound.sourceStart + visibleLength),
                                    sourceDuration: sound.sourceDuration, speed: 1)
        case .overlay:
            guard let overlay = overlays.first(where: { $0.id == id }) else { return nil }
            let clip = overlay.clip
            let visibleLength = min(clip.duration, max(0, duration - overlay.offset))
            return TimelineTrimSpan(offset: overlay.offset, sourceStart: clip.start,
                                    sourceEnd: min(clip.end, clip.start + visibleLength * clip.speed),
                                    sourceDuration: clip.sourceDuration, speed: clip.speed)
        }
    }
}
