import SwiftUI
import UIKit.UIGestureRecognizerSubclass

/// Captures a touch on a game control while the rest of the layout can scroll.
struct GameplayTouchSurface: UIViewRepresentable {
    enum Phase {
        case began, moved, ended, cancelled
    }

    var enabled = true
    let handle: (Phase, CGPoint) -> Void

    func makeUIView(context: Context) -> TouchView {
        let view = TouchView()
        view.isOpaque = false
        view.accessibilityElementsHidden = true
        view.addGestureRecognizer(GameplayTouchRecognizer(target: view, action: #selector(TouchView.receive(_:))))
        return view
    }

    func updateUIView(_ view: TouchView, context: Context) {
        view.handle = handle
        view.isUserInteractionEnabled = enabled
    }

    final class TouchView: UIView {
        var handle: ((Phase, CGPoint) -> Void)?

        @objc func receive(_ recognizer: UIGestureRecognizer) {
            switch recognizer.state {
            case .began: handle?(.began, recognizer.location(in: self))
            case .changed: handle?(.moved, recognizer.location(in: self))
            case .ended: handle?(.ended, recognizer.location(in: self))
            case .cancelled: handle?(.cancelled, .zero)
            default: break
            }
        }
    }
}

final class GameplayTouchRecognizer: UIGestureRecognizer {
    private var trackedTouch: UITouch?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let trackedTouch {
            ignoreOtherTouches(touches, than: trackedTouch, event: event)
            return
        }
        guard let touch = touches.first else { return }
        trackedTouch = touch
        ignoreOtherTouches(touches, than: touch, event: event)
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if let trackedTouch, touches.contains(trackedTouch) { state = .changed }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let trackedTouch, touches.contains(trackedTouch) { state = .ended }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        if let trackedTouch, touches.contains(trackedTouch) { state = .cancelled }
    }

    override func reset() {
        super.reset()
        trackedTouch = nil
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        if preventedGestureRecognizer is GameplayTouchRecognizer { return false }
        return super.canPrevent(preventedGestureRecognizer)
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        if let scrollView = preventingGestureRecognizer.view as? UIScrollView,
           scrollView.panGestureRecognizer === preventingGestureRecognizer {
            return false
        }
        return super.canBePrevented(by: preventingGestureRecognizer)
    }

    private func ignoreOtherTouches(_ touches: Set<UITouch>, than touch: UITouch, event: UIEvent) {
        for other in touches where other !== touch { ignore(other, for: event) }
    }
}

struct GameplayPressState {
    private(set) var isPressed = false

    mutating func handle(_ phase: GameplayTouchSurface.Phase) -> Bool {
        switch phase {
        case .began:
            guard !isPressed else { return false }
            isPressed = true
            return true
        case .ended, .cancelled:
            isPressed = false
        case .moved:
            break
        }
        return false
    }
}
