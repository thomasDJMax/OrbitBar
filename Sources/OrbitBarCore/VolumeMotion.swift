import Foundation

/// A frame shared by every volume presentation, independent of a UI or clock.
public struct VolumeMotionFrame: Equatable, Sendable {
    public var volume: Double
    public var emphasis: Double

    public init(volume: Double, emphasis: Double) {
        self.volume = Self.normalized(volume)
        self.emphasis = Self.normalized(emphasis)
    }

    private static func normalized(_ value: Double) -> Double {
        min(1, max(0, value.isFinite ? value : 0))
    }
}

/// A bounded, critically damped volume transition with a short activity pulse.
///
/// The caller supplies monotonic timestamps (for example, system uptime). A new
/// target retains the current position and velocity, so dragging or reversing a
/// slider does not restart the transition or make a displayed dot jump.
public struct VolumeMotion: Sendable {
    private var volume: Spring
    private var emphasis = Spring(value: 0)
    private var lastTime: Double?
    private var pulseDeadline: Double?

    public init(value: Double = 0) {
        volume = Spring(value: value)
    }

    /// True only while another frame can change the presentation.
    public var isActive: Bool {
        !volume.isSettled || !emphasis.isSettled || pulseDeadline != nil
    }

    public mutating func retarget(to value: Double, at time: Double, reducedMotion: Bool = false) {
        _ = sample(at: time)
        let target = Self.normalized(value)
        if reducedMotion {
            volume.snap(to: target)
            emphasis.snap(to: 0)
            pulseDeadline = nil
            return
        }

        // An unchanged system reading must not retrigger the pulse or keep a
        // render timer alive. Small changes still pulse within the same dot.
        guard abs(target - volume.target) > 0.000_001 else { return }
        volume.target = target
        emphasis.target = 1
        pulseDeadline = (lastTime ?? 0) + 0.08
    }

    public mutating func sample(at time: Double) -> VolumeMotionFrame {
        let now: Double
        if time.isFinite {
            now = max(lastTime ?? time, time)
        } else {
            now = lastTime ?? 0
        }
        let previous = lastTime ?? now
        let elapsed = now - previous
        lastTime = now

        if elapsed > 0 {
            volume.advance(by: elapsed, frequency: 22)
            volume.finishIfClose(positionTolerance: 0.000_5, velocityTolerance: 0.005)

            if let deadline = pulseDeadline {
                emphasis.advance(by: max(0, min(now, deadline) - previous), frequency: 45)
                if now >= deadline {
                    emphasis.target = 0
                    pulseDeadline = nil
                    emphasis.advance(by: max(0, now - max(previous, deadline)), frequency: 22)
                }
            } else {
                emphasis.advance(by: elapsed, frequency: 22)
            }
            if pulseDeadline == nil {
                emphasis.finishIfClose(positionTolerance: 0.001, velocityTolerance: 0.01)
            }
        }

        return VolumeMotionFrame(volume: volume.value, emphasis: emphasis.value)
    }

    /// Stops motion at the latest requested value, including when the user turns
    /// on Reduce Motion during an active transition.
    public mutating func settle(at time: Double) {
        _ = sample(at: time)
        volume.snap(to: volume.target)
        emphasis.snap(to: 0)
        pulseDeadline = nil
    }

    private static func normalized(_ value: Double) -> Double {
        min(1, max(0, value.isFinite ? value : 0))
    }

    private struct Spring: Sendable {
        var value: Double
        var velocity = 0.0
        var target: Double

        init(value: Double) {
            let value = VolumeMotion.normalized(value)
            self.value = value
            target = value
        }

        var isSettled: Bool { value == target && velocity == 0 }

        mutating func snap(to target: Double) {
            value = target
            self.target = target
            velocity = 0
        }

        mutating func advance(by elapsed: Double, frequency: Double) {
            guard elapsed > 0, !isSettled else { return }
            // Large clock jumps should finish, without inf * 0 arithmetic.
            guard elapsed < 2 else { snap(to: target); return }
            let offset = value - target
            let coefficient = velocity + frequency * offset
            let decay = exp(-frequency * elapsed)
            let next = target + (offset + coefficient * elapsed) * decay
            velocity = (velocity - frequency * coefficient * elapsed) * decay
            value = min(1, max(0, next))
            // Retained momentum can briefly carry a reversing slider into a
            // boundary. Remove the outward velocity there, never leave 0...1.
            if next < 0 || next > 1 { velocity = 0 }
        }

        mutating func finishIfClose(positionTolerance: Double, velocityTolerance: Double) {
            if abs(value - target) < positionTolerance && abs(velocity) < velocityTolerance {
                snap(to: target)
            }
        }
    }
}
