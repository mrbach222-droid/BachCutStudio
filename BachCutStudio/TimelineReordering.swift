import Foundation
import CoreGraphics

// A compact strip is used only while a clip is held. Timing is untouched.
enum TimelineReorderGeometry {
    static let width: CGFloat = 80
    static let spacing: CGFloat = 8
    static let stride = width + spacing
    static func index(at x: CGFloat, count: Int) -> Int {
        guard x.isFinite, count > 0 else { return 0 }
        let bounded = min(CGFloat(count - 1), max(0, ((x - width / 2) / stride).rounded()))
        return Int(bounded)
    }
    static func velocity(at x: CGFloat, viewport: CGFloat) -> CGFloat {
        guard x.isFinite, viewport.isFinite, viewport > 0 else { return 0 }
        let edge = min(56, viewport / 4)
        if x < edge { return -240 * min(1, max(0, (edge - x) / edge)) }
        if x > viewport - edge { return 240 * min(1, max(0, (x - viewport + edge) / edge)) }
        return 0
    }
}
