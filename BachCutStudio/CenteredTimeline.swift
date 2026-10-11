import SwiftUI
import UIKit

struct TimelineTrack {
    let id: UUID?
    let isOverlay: Bool
    let label: String
    let start: Double
    let duration: Double
    let color: UIColor
}

// UIKit owns scrolling and interactive movement; playback updates only move the offset.
struct CenteredTimeline: UIViewRepresentable {
    let project: StudioProject
    let selected: UUID?
    let thumbnails: [UUID: [UIImage]]
    let zoom: Double
    let playhead: Double
    let enabled: Bool
    let select: (UUID) -> Void
    let beginScrub: () -> Void
    let scrub: (Double) -> Void
    let endScrub: (Double) -> Void
    let changeZoom: (Double) -> Void
    let beginMove: (UUID) -> Void
    let move: (UUID, Int) -> Void
    let tapTrack: (UUID, Bool) -> Void
    let beginTrackDrag: () -> Void
    let moveTrack: (UUID, Bool, Double) -> Void
    let trimItem: (UUID, TimelineItemKind, TimelineTrimEdge, Double) -> Void

    func makeUIView(context: Context) -> TimelineSurface { TimelineSurface() }
    func updateUIView(_ view: TimelineSurface, context: Context) {
        view.onSelect = select; view.onBeginScrub = beginScrub; view.onScrub = scrub
        view.onEndScrub = endScrub; view.onZoomChange = changeZoom
        view.onBeginMove = beginMove; view.onMove = move
        view.onTapTrack = tapTrack; view.onBeginTrackDrag = beginTrackDrag; view.onMoveTrack = moveTrack
        view.onTrimItem = trimItem
        view.apply(project: project, selected: selected, thumbnails: thumbnails, zoom: zoom, playhead: playhead, enabled: enabled)
    }
    static func dismantleUIView(_ view: TimelineSurface, coordinator: ()) { view.cancelInteraction() }
}

final class TimelineSurface: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate {
    let layout = UICollectionViewFlowLayout()
    lazy var collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private let canvas = TimelineMarks()
    private let line = UIView()
    private let timeLabel = UILabel()
    private var clips: [VideoSegment] = []
    private var projectID: UUID?
    private var tracks: [TimelineTrack] = []
    private var trackHandles: [UUID: TimelineTrackHandle] = [:]
    private var draggingTrack: UUID?
    private var trackDragStart = 0.0
    private struct TrimKey: Hashable { let id: UUID; let kind: TimelineItemKind; let edge: TimelineTrimEdge }
    private struct TrimItem {
        let id: UUID; let kind: TimelineItemKind; let span: TimelineTrimSpan
        let y: CGFloat; let height: CGFloat; let color: UIColor; let label: String
    }
    private struct TrimSession {
        let key: TrimKey; let original: TimelineTrimSpan; let timelineDuration: Double
        var current: TimelineTrimSpan; var delta: Double
    }
    private var trimItems: [TrimItem] = []
    private var trimHandles: [TrimKey: TimelineTrimHandle] = [:]
    private var activeTrim: TrimSession?
    private let trimOutline = UIView()
    private let trimCaption = UILabel()
    private var selected: UUID?
    private var thumbnails: [UUID: [UIImage]] = [:]
    private var zoom = 24.0
    private var time = 0.0
    private var duration = 0.0
    private var userScrolling = false
    private var pinching = false
    private var pinchStartZoom = 24.0
    private var moving = false
    private struct ReorderSession {
        let original: [VideoSegment]
        let id: UUID
        let origin: Int
        var target: Int
    }
    private var reorderSession: ReorderSession?
    private var reorderPoint = CGPoint.zero
    private var reorderDisplayLink: CADisplayLink?
    private var reorderTicker: TimelineReorderTicker?
    private var reorderGhost: TimelineCell?
    private let reorderGap = UIView()
    private let reorderHint = UILabel()
    private var synchronizing = false
    private var lastWidth: CGFloat = 0
    private var lastScrub: CFTimeInterval = 0
    var onSelect: ((UUID) -> Void)?
    var onBeginScrub: (() -> Void)?
    var onScrub: ((Double) -> Void)?
    var onEndScrub: ((Double) -> Void)?
    var onZoomChange: ((Double) -> Void)?
    var onBeginMove: ((UUID) -> Void)?
    var onMove: ((UUID, Int) -> Void)?
    var onTapTrack: ((UUID, Bool) -> Void)?
    var onBeginTrackDrag: (() -> Void)?
    var onMoveTrack: ((UUID, Bool, Double) -> Void)?
    var onTrimItem: ((UUID, TimelineItemKind, TimelineTrimEdge, Double) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layout.scrollDirection = .horizontal; layout.minimumLineSpacing = 0; layout.minimumInteritemSpacing = 0
        collection.backgroundColor = .clear; collection.backgroundView = canvas
        collection.register(TimelineCell.self, forCellWithReuseIdentifier: "clip")
        collection.dataSource = self; collection.delegate = self
        collection.showsHorizontalScrollIndicator = false; collection.alwaysBounceHorizontal = true
        collection.contentInsetAdjustmentBehavior = .never; collection.decelerationRate = .fast
        collection.accessibilityIdentifier = "centeredTimeline"
        addSubview(collection)
        line.backgroundColor = .white; line.isUserInteractionEnabled = false
        line.layer.cornerRadius = 1; line.accessibilityIdentifier = "fixedPlayhead"
        addSubview(line)
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        timeLabel.textColor = .white
        timeLabel.textAlignment = .center
        timeLabel.backgroundColor = UIColor(white: 0.08, alpha: 0.92)
        timeLabel.layer.cornerRadius = 7
        timeLabel.clipsToBounds = true
        timeLabel.isUserInteractionEnabled = false
        timeLabel.accessibilityIdentifier = "timelineTimecode"
        addSubview(timeLabel)
        trimOutline.isUserInteractionEnabled = false; trimOutline.isHidden = true
        trimOutline.layer.borderWidth = 2; trimOutline.layer.cornerRadius = 4
        trimCaption.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        trimCaption.textColor = .white; trimCaption.textAlignment = .center
        trimCaption.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        trimCaption.clipsToBounds = true
        trimOutline.addSubview(trimCaption); insertSubview(trimOutline, belowSubview: line)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(longPress(_:)))
        hold.minimumPressDuration = 0.28; hold.allowableMovement = 14
        hold.delegate = self; addGestureRecognizer(hold)
        collection.panGestureRecognizer.require(toFail: hold)
        reorderGap.backgroundColor = UIColor.cyan.withAlphaComponent(0.15)
        reorderGap.layer.borderColor = UIColor.cyan.cgColor; reorderGap.layer.borderWidth = 2
        reorderGap.layer.cornerRadius = 5; reorderGap.isUserInteractionEnabled = false
        reorderGap.isHidden = true; reorderGap.isAccessibilityElement = true
        reorderGap.accessibilityIdentifier = "reorderInsertion"
        reorderGap.accessibilityLabel = "Vị trí chèn đoạn video"
        insertSubview(reorderGap, belowSubview: line)
        reorderHint.font = .systemFont(ofSize: 12, weight: .medium)
        reorderHint.textColor = .cyan; reorderHint.textAlignment = .center
        reorderHint.isUserInteractionEnabled = false; reorderHint.isHidden = true
        reorderHint.accessibilityIdentifier = "reorderHint"
        addSubview(reorderHint)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinchZoom(_:)))
        addGestureRecognizer(pinch)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        collection.frame = bounds
        layout.sectionInset = UIEdgeInsets(top: 28, left: 0, bottom: max(0, bounds.height - 88), right: 0)
        line.frame = CGRect(x: bounds.midX - 1, y: 23, width: 2, height: max(0, bounds.height - 23))
        timeLabel.frame = CGRect(x: bounds.midX - 38, y: 0, width: 76, height: 22)
        updateTimecode()
        if lastWidth != bounds.width {
            finishReorder(commit: false)
            cancelTrim()
            lastWidth = bounds.width
            synchronizing = true
            collection.contentInset = UIEdgeInsets(top: 0, left: bounds.width / 2, bottom: 0, right: bounds.width / 2)
            layout.invalidateLayout(); collection.layoutIfNeeded(); setPosition()
            synchronizing = false
        }
        updateMarks()
    }
    func apply(project: StudioProject, selected: UUID?, thumbnails: [UUID: [UIImage]], zoom: Double, playhead: Double, enabled: Bool) {
        if let session = reorderSession, !enabled || projectID != project.id || project.clips != session.original || self.zoom != zoom {
            finishReorder(commit: false)
        }
        projectID = project.id
        if let session = activeTrim,
           !enabled || self.zoom != zoom || project.duration != session.timelineDuration ||
           project.trimSpan(id: session.key.id, kind: session.key.kind) != session.original ||
           (session.key.kind == .video && selected != session.key.id) { cancelTrim() }
        let changed = clips != project.clips || self.zoom != zoom
        self.selected = selected; self.thumbnails = thumbnails; self.zoom = zoom
        duration = project.duration; time = playhead
        tracks = project.overlays.map { TimelineTrack(id: $0.id, isOverlay: true, label: "V2 · Lớp phủ", start: $0.offset, duration: min($0.clip.duration, max(0, duration - $0.offset)), color: .systemPurple) }
            + [TimelineTrack(id: nil, isOverlay: false, label: "A1 · Âm thanh nguồn", start: 0, duration: duration, color: .systemTeal)]
            + project.audio.map { TimelineTrack(id: $0.id, isOverlay: false, label: "A2 · Nhạc", start: $0.offset, duration: min($0.duration, max(0, duration - $0.offset)), color: .systemGreen) }
        canvas.tracks = tracks
        configureTrackHandles(enabled: enabled)
        configureTrimHandles(project: project, enabled: enabled)
        collection.isUserInteractionEnabled = enabled
        if changed && !moving {
            clips = project.clips
            synchronizing = true; collection.reloadData(); layout.invalidateLayout(); collection.layoutIfNeeded(); synchronizing = false
        }
        for index in collection.indexPathsForVisibleItems where clips.indices.contains(index.item) {
            let cell = collection.cellForItem(at: index) as? TimelineCell
            cell?.configure(clips[index.item], index: index.item, selected: clips[index.item].id == selected, image: thumbnails[clips[index.item].id], compact: moving)
            if moving { cell?.alpha = clips[index.item].id == reorderSession?.id ? 0 : 1 }
        }
        if !userScrolling && !moving { setPosition() }
        updateTimecode()
        updateMarks()
    }
    private func setPosition() {
        guard bounds.width > 0, !moving else { return }
        let x = CGFloat(time * zoom) - collection.contentInset.left
        if abs(collection.contentOffset.x - x) > 0.25 {
            synchronizing = true; collection.setContentOffset(CGPoint(x: x, y: 0), animated: false); synchronizing = false
        }
    }
    private var position: Double { min(duration, max(0, Double(collection.contentOffset.x + collection.contentInset.left) / zoom)) }
    private func updateTimecode() { timeLabel.text = formatTime(time) }

    // Only snap within a small visual threshold: precise scrubbing stays free elsewhere.
    // Calculate boundaries from the edited, speed-adjusted durations, not the source timestamps.
    static func snappedTime(_ value: Double, in clips: [VideoSegment], zoom: Double, thresholdPoints: Double = 10) -> Double {
        guard value.isFinite, zoom.isFinite, zoom > 0 else { return value }
        let threshold = max(0, thresholdPoints) / zoom
        var boundary = 0.0
        var result = value
        var distance = threshold
        for clip in clips {
            let gap = abs(value - boundary)
            if gap <= distance { result = boundary; distance = gap }
            boundary += clip.duration
        }
        let gap = abs(value - boundary)
        if gap <= distance { result = boundary }
        return result
    }
    // Clip handles are native views layered above the scroller; only the visible
    // position moves during a pan, so AVFoundation is never rebuilt on each frame.
    static func clampedTrackOffset(start: Double, dragPoints: CGFloat, zoom: Double,
                                   timelineDuration: Double, trackDuration: Double) -> Double {
        guard start.isFinite, dragPoints.isFinite, zoom.isFinite, zoom > 0,
              timelineDuration.isFinite, trackDuration.isFinite else { return 0 }
        return min(max(0, timelineDuration - trackDuration), max(0, start + Double(dragPoints) / zoom))
    }
    private func configureTrackHandles(enabled: Bool) {
        let active = Set(tracks.compactMap(\.id))
        for id in Array(trackHandles.keys) where !active.contains(id) {
            trackHandles[id]?.removeFromSuperview(); trackHandles.removeValue(forKey: id)
        }
        for track in tracks {
            guard let id = track.id else { continue }
            if trackHandles[id] == nil {
                let handle = TimelineTrackHandle(id: id, isOverlay: track.isOverlay)
                let pan = UIPanGestureRecognizer(target: self, action: #selector(dragTrack(_:)))
                pan.maximumNumberOfTouches = 1; pan.delegate = self; handle.addGestureRecognizer(pan)
                collection.panGestureRecognizer.require(toFail: pan)
                let tap = UITapGestureRecognizer(target: self, action: #selector(tapTrackHandle(_:)))
                handle.addGestureRecognizer(tap)
                insertSubview(handle, belowSubview: line)
                trackHandles[id] = handle
            }
            trackHandles[id]?.configure(label: track.label, color: track.color, enabled: enabled)
            trackHandles[id]?.isHidden = moving
        }
        updateTrackFrames()
        updateTrimFrames()
    }
    private func updateTrackFrames() {
        for (index, track) in tracks.enumerated() {
            guard let id = track.id, id != draggingTrack, let handle = trackHandles[id] else { continue }
            handle.frame = CGRect(x: -collection.contentOffset.x + CGFloat(track.start * zoom),
                                  y: CGFloat(96 + index * 44),
                                  width: CGFloat(max(1, track.duration * zoom)), height: 40)
            handle.accessibilityValue = formatTime(track.start)
        }
    }
    @objc private func tapTrackHandle(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let handle = gesture.view as? TimelineTrackHandle else { return }
        onTapTrack?(handle.trackID, handle.isOverlay)
    }
    @objc private func dragTrack(_ gesture: UIPanGestureRecognizer) {
        guard let handle = gesture.view as? TimelineTrackHandle,
              let track = tracks.first(where: { $0.id == handle.trackID }) else { return }
        switch gesture.state {
        case .began:
            guard !moving, !pinching, !userScrolling, activeTrim == nil else { return }
            draggingTrack = handle.trackID
            trackDragStart = track.start
            onBeginTrackDrag?()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .changed:
            guard draggingTrack == handle.trackID else { return }
            let proposed = Self.clampedTrackOffset(start: trackDragStart,
                dragPoints: gesture.translation(in: self).x, zoom: zoom,
                timelineDuration: duration, trackDuration: track.duration)
            handle.frame.origin.x = -collection.contentOffset.x + CGFloat(proposed * zoom)
            handle.accessibilityValue = formatTime(proposed)
        case .ended:
            guard draggingTrack == handle.trackID else { return }
            let proposed = Self.clampedTrackOffset(start: trackDragStart,
                dragPoints: gesture.translation(in: self).x, zoom: zoom,
                timelineDuration: duration, trackDuration: track.duration)
            draggingTrack = nil
            if abs(proposed - trackDragStart) > 0.001 {
                UISelectionFeedbackGenerator().selectionChanged()
                onMoveTrack?(handle.trackID, handle.isOverlay, proposed)
            } else { updateTrackFrames() }
        case .cancelled, .failed:
            if draggingTrack == handle.trackID { draggingTrack = nil; updateTrackFrames() }
        default: break
        }
    }
    private func updateMarks() {
        canvas.origin = -collection.contentOffset.x; canvas.zoom = zoom; canvas.duration = duration; canvas.setNeedsDisplay()
        updateTrackFrames()
        updateTrimFrames()
    }
    private func configureTrimHandles(project: StudioProject, enabled: Bool) {
        trimItems = []
        if let selected, let span = project.trimSpan(id: selected, kind: .video) {
            trimItems.append(TrimItem(id: selected, kind: .video, span: span, y: 28, height: 60, color: .cyan, label: "Video"))
        }
        for (index, track) in tracks.enumerated() {
            guard let id = track.id else { continue }
            let kind: TimelineItemKind = track.isOverlay ? .overlay : .audio
            guard let span = project.trimSpan(id: id, kind: kind) else { continue }
            trimItems.append(TrimItem(id: id, kind: kind, span: span, y: CGFloat(96 + index * 44), height: 40,
                                      color: track.color, label: track.isOverlay ? "Lớp phủ" : "Nhạc"))
        }
        trimItems.removeAll { $0.span.adjusted(edge: .end, delta: 0, kind: $0.kind, timelineDuration: duration) == nil }
        let keys = Set(trimItems.flatMap { item in
            [TrimKey(id: item.id, kind: item.kind, edge: .start), TrimKey(id: item.id, kind: item.kind, edge: .end)]
        })
        for key in Array(trimHandles.keys) where !keys.contains(key) {
            trimHandles.removeValue(forKey: key)?.removeFromSuperview()
        }
        for item in trimItems {
            for edge in [TimelineTrimEdge.start, .end] {
                let key = TrimKey(id: item.id, kind: item.kind, edge: edge)
                if trimHandles[key] == nil {
                    let handle = TimelineTrimHandle(id: item.id, kind: item.kind, edge: edge)
                    handle.adjust = { [weak self] delta in
                        guard let self, self.activeTrim == nil else { return }
                        self.onTrimItem?(key.id, key.kind, key.edge, delta)
                    }
                    let pan = UIPanGestureRecognizer(target: self, action: #selector(dragTrimHandle(_:)))
                    pan.maximumNumberOfTouches = 1; pan.delegate = self; handle.addGestureRecognizer(pan)
                    insertSubview(handle, belowSubview: line); trimHandles[key] = handle
                }
                trimHandles[key]?.configure(label: item.label, color: item.color, enabled: enabled)
            }
        }
        insertSubview(trimOutline, belowSubview: line)
        for handle in trimHandles.values { insertSubview(handle, belowSubview: line) }
        updateTrimFrames()
    }
    private func updateTrimFrames() {
        for item in trimItems {
            let session = activeTrim.flatMap { $0.key.id == item.id && $0.key.kind == item.kind ? $0 : nil }
            let span = session?.current ?? item.span
            // While dragging a main in-point, show the removed region. On release
            // the new main range ripples back against the preceding clip.
            let ripplePreview = item.kind == .video && session?.key.edge == .start
                ? (span.sourceStart - item.span.sourceStart) / span.speed : 0
            let x = -collection.contentOffset.x + CGFloat((span.offset + ripplePreview) * zoom)
            let width = CGFloat(span.duration * zoom)
            let leftCenter = min(max(6, x - 7), max(6, bounds.width - 6))
            let rightCenter = min(max(6, x + width + 7), max(6, bounds.width - 6))
            let hitWidth = x >= -8 && x + width <= bounds.width + 8
                ? min(44, max(1, rightCenter - leftCenter)) : 44
            for edge in [TimelineTrimEdge.start, .end] {
                let key = TrimKey(id: item.id, kind: item.kind, edge: edge)
                guard let handle = trimHandles[key] else { continue }
                let boundary = edge == .start ? x : x + width
                let center = edge == .start ? leftCenter : rightCenter
                // Short ranges have disjoint hit regions, rather than one edge
                // stealing the other's touches. Wider ranges get a 44 pt target.
                handle.frame = CGRect(x: center - hitWidth / 2, y: item.y, width: hitWidth, height: item.height)
                // Keep near-edge grips reachable, and never hide the view that
                // owns an active gesture when its boundary leaves the viewport.
                handle.isHidden = moving || (activeTrim?.key != key && (boundary < -8 || boundary > bounds.width + 8))
                handle.accessibilityValue = formatTime(edge == .start ? span.sourceStart : span.sourceEnd)
            }
            if session != nil {
                trimOutline.frame = CGRect(x: x, y: item.y, width: max(1, width), height: item.height)
                trimOutline.layer.borderColor = item.color.cgColor
                trimCaption.frame = CGRect(x: 2, y: max(2, item.height - 19), width: max(0, width - 4), height: 17)
                trimCaption.text = formatTime(span.duration)
                trimOutline.isHidden = false
            }
        }
    }
    @objc private func dragTrimHandle(_ gesture: UIPanGestureRecognizer) {
        guard let handle = gesture.view as? TimelineTrimHandle else { return }
        let key = TrimKey(id: handle.itemID, kind: handle.kind, edge: handle.edge)
        switch gesture.state {
        case .began:
            guard !moving, !pinching, !userScrolling, draggingTrack == nil, activeTrim == nil,
                  let item = trimItems.first(where: { $0.id == key.id && $0.kind == key.kind }) else { return }
            activeTrim = TrimSession(key: key, original: item.span, timelineDuration: duration, current: item.span, delta: 0)
            onBeginTrackDrag?(); setTrimmedItemAlpha(0.45)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            updateTrimPreview(gesture)
        case .changed:
            guard activeTrim?.key == key else { return }
            updateTrimPreview(gesture)
        case .ended:
            guard activeTrim?.key == key else { return }
            updateTrimPreview(gesture)
            guard let session = activeTrim else { return }
            cancelTrim()
            if session.current != session.original {
                UISelectionFeedbackGenerator().selectionChanged()
                onTrimItem?(key.id, key.kind, key.edge, session.delta)
            }
        case .cancelled, .failed:
            if activeTrim?.key == key { cancelTrim() }
        default: break
        }
    }
    private func updateTrimPreview(_ gesture: UIPanGestureRecognizer) {
        guard var session = activeTrim else { return }
        let delta = Double(gesture.translation(in: self).x) / zoom
        guard let span = session.original.adjusted(edge: session.key.edge, delta: delta,
            kind: session.key.kind, timelineDuration: session.timelineDuration) else { return }
        session.current = span; session.delta = delta; activeTrim = session
        updateTrimFrames()
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if let hold = gestureRecognizer as? UILongPressGestureRecognizer {
            // Selected short clips can be entirely covered by their trim grips.
            // A stationary hold on those grips should still lift the main clip;
            // an immediate pan continues to trim before the hold recognises.
            return collection.isUserInteractionEnabled && clips.count > 1 && !moving && !pinching &&
                activeTrim == nil && draggingTrack == nil && !userScrolling &&
                collection.indexPathForItem(at: hold.location(in: collection)) != nil
        }
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        let velocity = pan.velocity(in: self)
        // Leave vertical movement to the enclosing editor scroll view.
        return abs(velocity.x) > abs(velocity.y) && activeTrim == nil && draggingTrack == nil && !moving && !pinching && !userScrolling
    }
    private func setTrimmedItemAlpha(_ alpha: CGFloat) {
        guard let session = activeTrim else { return }
        if session.key.kind == .video, let index = clips.firstIndex(where: { $0.id == session.key.id }) {
            collection.cellForItem(at: IndexPath(item: index, section: 0))?.alpha = alpha
        } else { trackHandles[session.key.id]?.alpha = alpha }
    }
    private func cancelTrim() {
        setTrimmedItemAlpha(1); activeTrim = nil; trimOutline.isHidden = true
        updateTrimFrames()
    }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { clips.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "clip", for: indexPath) as! TimelineCell
        let clip = clips[indexPath.item]
        cell.configure(clip, index: indexPath.item, selected: clip.id == selected, image: thumbnails[clip.id], compact: moving)
        cell.alpha = moving && clip.id == reorderSession?.id ? 0 : 1
        return cell
    }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize { CGSize(width: moving ? TimelineReorderGeometry.width : max(1, clips[indexPath.item].duration * zoom), height: 60) }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) { if !moving { onSelect?(clips[indexPath.item].id) } }
    // Zoom is anchored at the fixed center playhead, independently of finger position.
    // Applying the layout locally first avoids waiting for a SwiftUI render to update cells.
    static func clampedZoom(start: Double, scale: CGFloat) -> Double {
        guard start.isFinite, scale.isFinite, scale > 0 else { return min(80, max(8, start.isFinite ? start : 24)) }
        return min(80, max(8, start * Double(scale)))
    }
    @objc private func pinchZoom(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard collection.isUserInteractionEnabled, !moving, activeTrim == nil, draggingTrack == nil else { return }
            pinching = true; pinchStartZoom = zoom
            if !userScrolling { onBeginScrub?() }
        case .changed:
            guard pinching else { return }
            let next = Self.clampedZoom(start: pinchStartZoom, scale: gesture.scale)
            guard abs(zoom - next) > 0.001 else { return }
            zoom = next
            layout.invalidateLayout(); collection.layoutIfNeeded()
            setPosition(); updateMarks()
            onZoomChange?(next)
        case .ended, .cancelled, .failed:
            guard pinching else { return }
            pinching = false
            // Seek once after the gesture; the visual playhead time does not change.
            userScrolling = false
            setPosition(); onEndScrub?(time)
        default: break
        }
    }
    @objc private func longPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard let index = collection.indexPathForItem(at: gesture.location(in: collection)) else { return }
            _ = beginReorder(at: index.item, point: gesture.location(in: self))
        case .changed:
            updateReorder(at: gesture.location(in: self))
        case .ended:
            updateReorder(at: gesture.location(in: self)); finishReorder(commit: true)
        default:
            finishReorder(commit: false)
        }
    }
    @discardableResult func beginReorder(at index: Int, point: CGPoint) -> Bool {
        guard collection.isUserInteractionEnabled, clips.count > 1, clips.indices.contains(index),
              !moving, !pinching, !userScrolling, activeTrim == nil, draggingTrack == nil,
              point.x.isFinite, point.y.isFinite else { return false }
        let clip = clips[index]
        reorderSession = ReorderSession(original: clips, id: clip.id, origin: index, target: index)
        moving = true; selected = clip.id; reorderPoint = point
        collection.isScrollEnabled = false; canvas.isHidden = true
        layout.minimumLineSpacing = TimelineReorderGeometry.spacing
        collection.reloadData(); layout.invalidateLayout(); collection.layoutIfNeeded()
        let center = CGFloat(index) * TimelineReorderGeometry.stride + TimelineReorderGeometry.width / 2
        setReorderOffset(center - point.x)
        let ghost = TimelineCell(frame: CGRect(x: 0, y: 0, width: TimelineReorderGeometry.width, height: 60))
        ghost.configure(clip, index: index, selected: true, image: thumbnails[clip.id], compact: true)
        ghost.isAccessibilityElement = false; ghost.isUserInteractionEnabled = false
        ghost.layer.shadowColor = UIColor.black.cgColor; ghost.layer.shadowOpacity = 0.45
        ghost.layer.shadowRadius = 5; ghost.layer.shadowOffset = CGSize(width: 0, height: 4)
        addSubview(ghost); reorderGhost = ghost
        reorderGap.isHidden = false; reorderHint.isHidden = false
        trackHandles.values.forEach { $0.isHidden = true }; trimHandles.values.forEach { $0.isHidden = true }
        updateReorderFeedback()
        let ticker = TimelineReorderTicker(); ticker.surface = self; reorderTicker = ticker
        let link = CADisplayLink(target: ticker, selector: #selector(TimelineReorderTicker.tick(_:)))
        link.preferredFramesPerSecond = 60; link.add(to: .main, forMode: .common); reorderDisplayLink = link
        onBeginMove?(clip.id)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        return true
    }
    func updateReorder(at point: CGPoint) {
        guard var session = reorderSession, point.x.isFinite, point.y.isFinite else { return }
        reorderPoint = point
        let x = min(bounds.width - 1, max(0, point.x)) + collection.contentOffset.x
        let target = TimelineReorderGeometry.index(at: x, count: clips.count)
        if target != session.target {
            let prior = session.target
            let clip = clips.remove(at: prior); clips.insert(clip, at: target)
            session.target = target; reorderSession = session
            collection.performBatchUpdates({
                collection.moveItem(at: IndexPath(item: prior, section: 0), to: IndexPath(item: target, section: 0))
            }, completion: { [weak self] _ in self?.refreshReorderCells() })
            UISelectionFeedbackGenerator().selectionChanged()
        }
        refreshReorderCells(); updateReorderFeedback()
    }
    private func refreshReorderCells() {
        guard let session = reorderSession else { return }
        for path in collection.indexPathsForVisibleItems where clips.indices.contains(path.item) {
            let clip = clips[path.item]
            let cell = collection.cellForItem(at: path) as? TimelineCell
            cell?.configure(clip, index: path.item, selected: clip.id == session.id, image: thumbnails[clip.id], compact: true)
            cell?.alpha = clip.id == session.id ? 0 : 1
        }
    }
    private func updateReorderFeedback() {
        guard let session = reorderSession else { return }
        reorderGap.frame = CGRect(x: CGFloat(session.target) * TimelineReorderGeometry.stride - collection.contentOffset.x,
                                  y: 28, width: TimelineReorderGeometry.width, height: 60)
        reorderGap.accessibilityValue = "\(session.target + 1)/\(clips.count)"
        reorderHint.frame = CGRect(x: 4, y: 94, width: max(0, bounds.width - 8), height: 22)
        reorderHint.text = "Thả để chèn · \(session.target + 1)/\(clips.count)"
        reorderGhost?.center = CGPoint(x: min(bounds.width - 1, max(0, reorderPoint.x)), y: 52)
    }
    private func setReorderOffset(_ value: CGFloat) {
        let lower = -collection.contentInset.left
        let upper = max(lower, collection.contentSize.width - bounds.width + collection.contentInset.right)
        collection.setContentOffset(CGPoint(x: min(upper, max(lower, value)), y: 0), animated: false)
    }
    func advanceReorder(by elapsed: TimeInterval) {
        guard moving, elapsed.isFinite, elapsed > 0 else { return }
        let velocity = TimelineReorderGeometry.velocity(at: reorderPoint.x, viewport: bounds.width)
        guard velocity != 0 else { return }
        setReorderOffset(collection.contentOffset.x + velocity * CGFloat(min(0.05, elapsed)))
        updateReorder(at: reorderPoint)
    }
    func finishReorder(commit: Bool) {
        guard let session = reorderSession else { return }
        reorderDisplayLink?.invalidate(); reorderDisplayLink = nil; reorderTicker = nil
        reorderGhost?.removeFromSuperview(); reorderGhost = nil
        reorderGap.isHidden = true; reorderHint.isHidden = true
        reorderSession = nil; moving = false
        if !commit { clips = session.original }
        canvas.isHidden = false; collection.isScrollEnabled = true; layout.minimumLineSpacing = 0
        collection.reloadData(); layout.invalidateLayout(); collection.layoutIfNeeded()
        trackHandles.values.forEach { $0.isHidden = false }
        setPosition(); updateMarks()
        if commit, session.target != session.origin { onMove?(session.id, session.target) }
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { finishReorder(commit: false) }
    }
    func cancelInteraction() {
        cancelTrim()
        finishReorder(commit: false)
        if pinching { pinching = false; onEndScrub?(time) }
        if userScrolling { finishScrub() }
        if draggingTrack != nil { draggingTrack = nil; updateTrackFrames() }
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard !pinching, !moving else { return }
        userScrolling = true; lastScrub = 0; onBeginScrub?()
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateMarks()
        guard userScrolling, !synchronizing, !moving, !pinching else { return }
        time = position
        updateTimecode()
        let now = CACurrentMediaTime()
        if now - lastScrub >= 1.0 / 30 { lastScrub = now; onScrub?(time) }
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate && !pinching { finishScrub() } }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { if !pinching { finishScrub() } }
    private func finishScrub() {
        guard userScrolling else { return }
        let releasedTime = position
        time = Self.snappedTime(releasedTime, in: clips, zoom: zoom)
        userScrolling = false
        if abs(time - releasedTime) > 0.0001 { UISelectionFeedbackGenerator().selectionChanged() }
        updateTimecode()
        onEndScrub?(time)
        setPosition()
    }
}

private final class TimelineReorderTicker: NSObject {
    weak var surface: TimelineSurface?
    @objc func tick(_ link: CADisplayLink) { surface?.advanceReorder(by: link.targetTimestamp - link.timestamp) }
}

private final class TimelineCell: UICollectionViewCell {
    private let label = UILabel()
    private var sourceImages: [UIImage] = []
    private var filmFrames: [UIImageView] = []
    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.clipsToBounds = true; contentView.layer.cornerRadius = 4
        label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium); label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.65); contentView.addSubview(label)
        isAccessibilityElement = true; accessibilityTraits = .button
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = CGRect(x: 4, y: 40, width: min(70, max(0, bounds.width - 8)), height: 18)
        for (index, frame) in filmFrames.enumerated() {
            let width = bounds.width / CGFloat(filmFrames.count)
            frame.frame = CGRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height)
        }
    }
    func configure(_ clip: VideoSegment, index: Int, selected: Bool, image: [UIImage]?, compact: Bool = false) {
        label.text = formatTime(clip.duration)
        accessibilityIdentifier = "clip_\(index)"; accessibilityLabel = "Đoạn \(index + 1), \(formatTime(clip.duration))"
        accessibilityTraits = selected ? [.button, .selected] : .button
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitesting") { accessibilityValue = clip.id.uuidString }
        #endif
        contentView.layer.borderWidth = selected ? 3 : 1; contentView.layer.borderColor = selected ? UIColor.cyan.cgColor : UIColor.black.cgColor
        let originals = image ?? []
        let images = compact && originals.count > 3 ? (0..<3).map { originals[$0 * (originals.count - 1) / 2] } : originals
        if sourceImages.count != images.count || zip(sourceImages, images).contains(where: { $0.0 !== $0.1 }) {
            filmFrames.forEach { $0.removeFromSuperview() }; filmFrames.removeAll()
            sourceImages = images
            for frameImage in images {
                let view = UIImageView(image: frameImage)
                view.contentMode = .scaleAspectFill; view.clipsToBounds = true
                contentView.insertSubview(view, at: 0); filmFrames.append(view)
            }
            setNeedsLayout()
        }
        contentView.backgroundColor = UIColor(red: 0.12, green: 0.22, blue: 0.28, alpha: 1)
    }
    override func prepareForReuse() {
        super.prepareForReuse()
        alpha = 1
        filmFrames.forEach { $0.removeFromSuperview() }; filmFrames.removeAll(); sourceImages.removeAll()
    }
}

private final class TimelineMarks: UIView {
    var origin: CGFloat = 0
    var zoom = 24.0
    var duration = 0.0
    var tracks: [TimelineTrack] = []
    override init(frame: CGRect) { super.init(frame: frame); backgroundColor = UIColor.white.withAlphaComponent(0.035); isUserInteractionEnabled = false }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        let step = max(1, Int(80 / zoom))
        let first = max(0, Int(floor(Double(-origin) / zoom / Double(step))) * step)
        let last = min(Int(ceil(duration)), Int(ceil(Double(bounds.width - origin) / zoom)))
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular), .foregroundColor: UIColor.lightGray]
        if first <= last {
            for second in stride(from: first, through: last, by: step) {
                let x = origin + CGFloat(Double(second) * zoom)
                (formatTime(Double(second)) as NSString).draw(at: CGPoint(x: x + 2, y: 3), withAttributes: attributes)
                UIColor.gray.setFill(); UIRectFill(CGRect(x: x, y: 21, width: 1, height: 5))
            }
        }
        for (index, track) in tracks.enumerated() {
            // Interactive audio and overlay blocks are native pan-enabled views above this canvas.
            guard track.id == nil else { continue }
            let box = CGRect(x: origin + track.start * zoom, y: Double(96 + index * 44), width: track.duration * zoom, height: 40)
            let visible = box.intersection(bounds)
            guard !visible.isNull else { continue }
            track.color.withAlphaComponent(0.25).setFill(); UIRectFill(visible)
            (track.label as NSString).draw(at: CGPoint(x: max(box.minX + 5, 5), y: box.minY + 6), withAttributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: UIColor.white])
        }
    }
}

private final class TimelineTrackHandle: UIView {
    let trackID: UUID
    let isOverlay: Bool
    private let caption = UILabel()
    init(id: UUID, isOverlay: Bool) {
        self.trackID = id; self.isOverlay = isOverlay
        super.init(frame: .zero)
        layer.cornerRadius = 5; layer.borderWidth = 1.5; layer.borderColor = UIColor.white.withAlphaComponent(0.6).cgColor
        clipsToBounds = true
        caption.font = .systemFont(ofSize: 10, weight: .semibold)
        caption.textColor = .white; caption.lineBreakMode = .byTruncatingTail
        caption.isUserInteractionEnabled = false; addSubview(caption)
        isAccessibilityElement = true
        accessibilityTraits = [.button, .allowsDirectInteraction]
        accessibilityIdentifier = (isOverlay ? "overlayTrack_" : "audioTrack_") + id.uuidString
        accessibilityHint = "Kéo ngang để đổi vị trí. Chạm để sửa thời lượng."
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        caption.frame = bounds.insetBy(dx: 5, dy: 3)
    }
    func configure(label: String, color: UIColor, enabled: Bool) {
        caption.text = "↔ " + label
        backgroundColor = color.withAlphaComponent(0.65)
        isUserInteractionEnabled = enabled
        accessibilityLabel = label
    }
}

private final class TimelineTrimHandle: UIView {
    let itemID: UUID
    let kind: TimelineItemKind
    let edge: TimelineTrimEdge
    var adjust: ((Double) -> Void)?
    private let grip = UIView()
    private let mark = UIView()
    init(id: UUID, kind: TimelineItemKind, edge: TimelineTrimEdge) {
        itemID = id; self.kind = kind; self.edge = edge
        super.init(frame: .zero)
        grip.layer.cornerRadius = 4; grip.isUserInteractionEnabled = false
        mark.backgroundColor = .white; mark.layer.cornerRadius = 1
        grip.addSubview(mark); addSubview(grip)
        isAccessibilityElement = true; accessibilityTraits = [.adjustable]
        let type = kind == .video ? "Video" : kind == .audio ? "Audio" : "Overlay"
        accessibilityIdentifier = "trim" + type + (edge == .start ? "Start" : "End") + (kind == .video ? "" : "_" + id.uuidString)
        accessibilityHint = "Kéo ngang để cắt. Vuốt lên hoặc xuống để chỉnh 0,1 giây."
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        grip.frame = CGRect(x: bounds.midX - 6, y: 2, width: 12, height: max(0, bounds.height - 4))
        mark.frame = CGRect(x: 5, y: max(4, grip.bounds.midY - 8), width: 2, height: 16)
    }
    func configure(label: String, color: UIColor, enabled: Bool) {
        grip.backgroundColor = color; isUserInteractionEnabled = enabled
        accessibilityTraits = enabled ? [.adjustable] : [.adjustable, .notEnabled]
        accessibilityLabel = (edge == .start ? "Cắt đầu " : "Cắt cuối ") + label.lowercased()
    }
    override func accessibilityIncrement() { if isUserInteractionEnabled { adjust?(0.1) } }
    override func accessibilityDecrement() { if isUserInteractionEnabled { adjust?(-0.1) } }
}
