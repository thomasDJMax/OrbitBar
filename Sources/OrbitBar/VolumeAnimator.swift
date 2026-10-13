import AppKit
import Combine
import OrbitBarCore

/// One clock feeds the menu icon, popover, and settings preview.
@MainActor
final class VolumeAnimator: ObservableObject {
    @Published private(set) var frame: VolumeMotionFrame
    private var motion: VolumeMotion
    private var target: Double
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var isSleeping = false

    init(value: Double = 0) {
        var motion = VolumeMotion(value: value)
        let initialFrame = motion.sample(at: ProcessInfo.processInfo.systemUptime)
        self.frame = initialFrame
        self.motion = motion
        target = initialFrame.volume
        observe(NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                center: NSWorkspace.shared.notificationCenter) { animator in
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { animator.settle() }
        }
        observe(.NSProcessInfoPowerStateDidChange, center: .default) { animator in
            animator.invalidateTimer()
            animator.startTimerIfNeeded()
        }
        observe(NSWorkspace.willSleepNotification, center: NSWorkspace.shared.notificationCenter) { animator in
            animator.isSleeping = true
            animator.settle()
        }
        observe(NSWorkspace.didWakeNotification, center: NSWorkspace.shared.notificationCenter) { animator in
            animator.isSleeping = false
        }
    }

    func setVolume(_ value: Double, animated: Bool = true) {
        let next = min(1, max(0, value.isFinite ? value : 0))
        let immediate = !animated || isSleeping || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard abs(next - target) > 0.000_001 || immediate && motion.isActive else { return }
        target = next
        let now = ProcessInfo.processInfo.systemUptime
        motion.retarget(to: next, at: now, reducedMotion: immediate)
        publish(motion.sample(at: now))
        if motion.isActive { startTimerIfNeeded() } else { invalidateTimer() }
    }

    func stop() {
        settle()
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    private func settle() {
        let now = ProcessInfo.processInfo.systemUptime
        motion.settle(at: now)
        publish(motion.sample(at: now))
        invalidateTimer()
    }

    private func tick() {
        publish(motion.sample(at: ProcessInfo.processInfo.systemUptime))
        if !motion.isActive { invalidateTimer() }
    }

    private func publish(_ next: VolumeMotionFrame) {
        if next != frame { frame = next }
    }

    private func startTimerIfNeeded() {
        guard timer == nil, motion.isActive, !isSleeping else { return }
        let rate = ProcessInfo.processInfo.isLowPowerModeEnabled ? 30.0 : 60.0
        let timer = Timer(timeInterval: 1 / rate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.002
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func invalidateTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func observe(_ name: Notification.Name, center: NotificationCenter,
                         handler: @escaping @MainActor (VolumeAnimator) -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                if let self { handler(self) }
            }
        }
        observers.append((center, observer))
    }
}
