import CoreGraphics
import Foundation

/// Smooths every crop change so zooming and scene switches glide.
///
/// Implemented as frame-rate independent exponential smoothing rather than a
/// classic spring: with no overshoot there is never a moment where the crop
/// leaves the source bounds, and the response is identical whether the camera
/// delivers 30 or 60 fps.
public struct CropAnimator: Sendable {
    /// Time to cover ~63% of the remaining distance. 90 ms reads as immediate
    /// but still removes the stepping of a raw scroll wheel.
    public var timeConstant: Double

    public private(set) var current: CropState
    public var target: CropState

    /// Below this the remaining motion is invisible, so we snap and stop doing work.
    private let epsilon: CGFloat = 0.0002

    public init(state: CropState = .identity, timeConstant: Double = 0.09) {
        self.current = state
        self.target = state
        self.timeConstant = timeConstant
    }

    public var isSettled: Bool {
        abs(current.center.x - target.center.x) < epsilon
            && abs(current.center.y - target.center.y) < epsilon
            && abs(log(current.zoom) - log(target.zoom)) < epsilon
    }

    /// Jumps straight to a state, skipping the animation.
    public mutating func snap(to state: CropState) {
        current = state
        target = state
    }

    @discardableResult
    public mutating func advance(deltaTime: Double) -> CropState {
        guard deltaTime > 0 else { return current }
        if isSettled {
            current = target
            return current
        }
        let alpha = CGFloat(1 - exp(-deltaTime / max(timeConstant, 0.001)))
        current = CropGeometry.interpolate(from: current, to: target, t: alpha)
        return current
    }
}
