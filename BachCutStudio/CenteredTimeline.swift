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

    func makeUIView(context: Context) -> TimelineSurface { TimelineSurface() }
    func updateUIView(_ view: TimelineSurface, context: Context) {
        view.onSelect = select; view.onBeginScrub = beginScrub; view.onScrub = scrub
        view.onEndScrub = endScrub; view.onZoomChange = changeZoom
        view.onBeginMove = beginMove; view.onMove = move
        view.onTapTrack = tapTrack; view.onBeginTrackDrag = beginTrackDrag; view.onMoveTrack = moveTrack
        view.apply(project: project, selected: selected, thumbnails: thumbnails, zoom: zoom, playhead: playhead, enabled: enabled)
    }
    static func dismantleUIView(_ view: TimelineSurface, coordinator: ()) { view.cancelInteraction() }
}

final class TimelineSurface: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    let layout = UICollectionViewFlowLayout()
    lazy var collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
    private let canvas = TimelineMarks()
    private let line = UIView()
    private let timeLabel = UILabel()
    private var clips: [VideoSegment] = []
    private var tracks: [TimelineTrack] = []
    private var trackHandles: [UUID: TimelineTrackHandle] = [:]
    private var draggingTrack: UUID?
    private var trackDragStart = 0.0
    private var selected: UUID?
    private var thumbnails: [UUID: [UIImage]] = [:]
    private var zoom = 24.0
    private var time = 0.0
    private var duration = 0.0
    private var userScrolling = false
    private var pinching = false
    private var pinchStartZoom = 24.0
    private var moving = false
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
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(longPress(_:)))
        hold.minimumPressDuration = 0.35; collection.addGestureRecognizer(hold)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinchZoom(_:)))
        collection.addGestureRecognizer(pinch)
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
            lastWidth = bounds.width
            synchronizing = true
            collection.contentInset = UIEdgeInsets(top: 0, left: bounds.width / 2, bottom: 0, right: bounds.width / 2)
            layout.invalidateLayout(); collection.layoutIfNeeded(); setPosition()
            synchronizing = false
        }
        updateMarks()
    }
    func apply(project: StudioProject, selected: UUID?, thumbnails: [UUID: [UIImage]], zoom: Double, playhead: Double, enabled: Bool) {
        let changed = clips != project.clips || self.zoom != zoom
        self.selected = selected; self.thumbnails = thumbnails; self.zoom = zoom
        duration = project.duration; time = playhead
        tracks = project.overlays.map { TimelineTrack(id: $0.id, isOverlay: true, label: "V2 · Lớp phủ", start: $0.offset, duration: min($0.clip.duration, max(0, duration - $0.offset)), color: .systemPurple) }
            + [TimelineTrack(id: nil, isOverlay: false, label: "A1 · Âm thanh nguồn", start: 0, duration: duration, color: .systemTeal)]
            + project.audio.map { TimelineTrack(id: $0.id, isOverlay: false, label: "A2 · Nhạc", start: $0.offset, duration: min($0.duration, max(0, duration - $0.offset)), color: .systemGreen) }
        canvas.tracks = tracks
        configureTrackHandles(enabled: enabled)
        collection.isUserInteractionEnabled = enabled
        if changed && !moving {
            clips = project.clips
            synchronizing = true; collection.reloadData(); layout.invalidateLayout(); collection.layoutIfNeeded(); synchronizing = false
        }
        for index in collection.indexPathsForVisibleItems where clips.indices.contains(index.item) {
            (collection.cellForItem(at: index) as? TimelineCell)?.configure(clips[index.item], index: index.item, selected: clips[index.item].id == selected, image: thumbnails[clips[index.item].id])
        }
        if !userScrolling && !moving { setPosition() }
        updateTimecode()
        updateMarks()
    }
    private func setPosition() {
        guard bounds.width > 0 else { return }
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
                pan.maximumNumberOfTouches = 1; handle.addGestureRecognizer(pan)
                collection.panGestureRecognizer.require(toFail: pan)
                let tap = UITapGestureRecognizer(target: self, action: #selector(tapTrackHandle(_:)))
                handle.addGestureRecognizer(tap)
                insertSubview(handle, belowSubview: line)
                trackHandles[id] = handle
            }
            trackHandles[id]?.configure(label: track.label, color: track.color, enabled: enabled)
        }
        updateTrackFrames()
    }
    private func updateTrackFrames() {
        for (index, track) in tracks.enumerated() {
            guard let id = track.id, id != draggingTrack, let handle = trackHandles[id] else { continue }
            handle.frame = CGRect(x: -collection.contentOffset.x + CGFloat(track.start * zoom),
                                  y: CGFloat(96 + index * 32),
                                  width: CGFloat(max(1, track.duration * zoom)), height: 26)
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
            guard !moving, !pinching, !userScrolling else { return }
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
    }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { clips.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "clip", for: indexPath) as! TimelineCell
        let clip = clips[indexPath.item]
        cell.configure(clip, index: indexPath.item, selected: clip.id == selected, image: thumbnails[clip.id]); return cell
    }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize { CGSize(width: max(1, clips[indexPath.item].duration * zoom), height: 60) }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) { onSelect?(clips[indexPath.item].id) }
    func collectionView(_ collectionView: UICollectionView, canMoveItemAt indexPath: IndexPath) -> Bool { clips.count > 1 }
    func collectionView(_ collectionView: UICollectionView, moveItemAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        let clip = clips.remove(at: sourceIndexPath.item); clips.insert(clip, at: destinationIndexPath.item)
        moving = false; onMove?(clip.id, destinationIndexPath.item)
        // Durations travel with their clips; rebuild widths and accessibility indices after the drop.
        DispatchQueue.main.async { [weak self] in self?.collection.reloadData(); self?.layout.invalidateLayout() }
    }
    // Zoom is anchored at the fixed center playhead, independently of finger position.
    // Applying the layout locally first avoids waiting for a SwiftUI render to update cells.
    static func clampedZoom(start: Double, scale: CGFloat) -> Double {
        guard start.isFinite, scale.isFinite, scale > 0 else { return min(80, max(8, start.isFinite ? start : 24)) }
        return min(80, max(8, start * Double(scale)))
    }
    @objc private func pinchZoom(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard !moving else { return }
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
        let location = gesture.location(in: collection)
        switch gesture.state {
        case .began:
            guard let index = collection.indexPathForItem(at: location), clips.count > 1 else { return }
            onBeginMove?(clips[index.item].id)
            moving = collection.beginInteractiveMovementForItem(at: index)
            if moving { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        case .changed:
            if moving { collection.updateInteractiveMovementTargetPosition(location) }
        case .ended:
            if moving { collection.endInteractiveMovement(); moving = false; setPosition() }
        default:
            if moving { collection.cancelInteractiveMovement(); moving = false; setPosition() }
        }
    }
    func cancelInteraction() {
        if moving { collection.cancelInteractiveMovement(); moving = false }
        if pinching { pinching = false; onEndScrub?(time) }
        if userScrolling { finishScrub() }
        if draggingTrack != nil { draggingTrack = nil; updateTrackFrames() }
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard !pinching else { return }
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
    func configure(_ clip: VideoSegment, index: Int, selected: Bool, image: [UIImage]?) {
        label.text = formatTime(clip.duration)
        accessibilityIdentifier = "clip_\(index)"; accessibilityLabel = "Đoạn \(index + 1), \(formatTime(clip.duration))"
        accessibilityTraits = selected ? [.button, .selected] : .button
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--uitesting") { accessibilityValue = clip.id.uuidString }
        #endif
        contentView.layer.borderWidth = selected ? 3 : 1; contentView.layer.borderColor = selected ? UIColor.cyan.cgColor : UIColor.black.cgColor
        let images = image ?? []
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
            let box = CGRect(x: origin + track.start * zoom, y: Double(96 + index * 32), width: track.duration * zoom, height: 26)
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
