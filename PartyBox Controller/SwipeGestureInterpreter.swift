import CoreGraphics
import PartyBoxCore

/// Pure gesture math for the swipe (trackpad) touch style, kept out of the
/// views so it can be unit-tested. Locations are SwiftUI points, so y grows
/// downward; every result uses PartyBox's y-up convention.
enum SwipeGestureInterpreter {
    /// Finger travel needed before a swipe pad registers a turn.
    static let turnThreshold: CGFloat = 24
    /// Finger travel needed before a heading surface re-aims the stick.
    static let headingThreshold: CGFloat = 12
    /// Full surface width of drag moves a relative stick this many half-ranges.
    static let relativeSensitivity: CGFloat = 1.6

    /// Turns one continuous stroke into direction-pad choices. After each turn
    /// the anchor jumps to the finger, so drawing an "L" yields two turns
    /// without lifting, like dragging on a trackpad.
    struct DirectionTracker: Equatable {
        private(set) var anchor: CGPoint?
        private(set) var lastDirection: String?

        mutating func update(to location: CGPoint) -> String? {
            guard let start = anchor else {
                anchor = location
                return nil
            }
            let dx = location.x - start.x
            let dy = start.y - location.y
            guard max(abs(dx), abs(dy)) >= SwipeGestureInterpreter.turnThreshold else { return nil }
            let direction = abs(dx) > abs(dy) ? (dx > 0 ? "right" : "left") : (dy > 0 ? "up" : "down")
            anchor = location
            guard direction != lastDirection else { return nil }
            lastDirection = direction
            return direction
        }

        mutating func end() {
            anchor = nil
            lastDirection = nil
        }
    }

    /// Aims a full-strength stick along the direction the finger is travelling.
    /// A tap that never travels releases the stick.
    struct HeadingTracker: Equatable {
        private(set) var anchor: CGPoint?
        private(set) var travelled = false

        mutating func update(to location: CGPoint) -> (x: Float, y: Float)? {
            guard let start = anchor else {
                anchor = location
                return nil
            }
            let dx = location.x - start.x
            let dy = start.y - location.y
            let distance = (dx * dx + dy * dy).squareRoot()
            guard distance >= SwipeGestureInterpreter.headingThreshold else { return nil }
            anchor = location
            travelled = true
            return (Float(dx / distance), Float(dy / distance))
        }

        /// Ends the stroke and reports whether it was a tap (no travel).
        mutating func end() -> Bool {
            defer {
                anchor = nil
                travelled = false
            }
            return !travelled
        }
    }

    /// Moves a stick value by a finger delta, like a cursor on a trackpad.
    /// `delta` is in points along the axis with y already flipped to y-up.
    static func relativeAxis(current: Float, delta: CGFloat, extent: CGFloat) -> Float {
        guard extent > 0, delta.isFinite, current.isFinite else { return current.isFinite ? current : 0 }
        let change = Float((delta / extent) * 2 * relativeSensitivity)
        return min(max(current + change, -1), 1)
    }

    /// Whether the in-game touch-style toggle applies to this screen.
    static func offersTouchStyle(_ screen: ControllerScreen) -> Bool {
        screen.components.contains { component in
            switch component {
            case .axisSurface, .directionPad: true
            default: false
            }
        }
    }
}
