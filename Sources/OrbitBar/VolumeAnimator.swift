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
    private var isStopped = false
    private var lifecycle = ObserverLifecycle()
    private var isPublishing = false
    private var pendingVolume: (value: Double, animated: Bool)?
    private var pendingSettlement = false
    private var isDrainingCommands = false
    private let clock: @MainActor () -> Double
    private let reduceMotion: @MainActor () -> Bool
    private let lowPowerMode: @MainActor () -> Bool

    var isAnimating: Bool { timer != nil }
    var frameInterval: Double? { timer?.timeInterval }

    init(value: Double = 0,
         clock: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime },
         reduceMotion: @escaping @MainActor () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         lowPowerMode: @escaping @MainActor () -> Bool = { ProcessInfo.processInfo.isLowPowerModeEnabled },
         workspaceCenter: NotificationCenter? = nil, systemCenter: NotificationCenter = .default) {
        self.clock = clock
        self.reduceMotion = reduceMotion
        self.lowPowerMode = lowPowerMode
        let workspaceCenter = workspaceCenter ?? NSWorkspace.shared.notificationCenter
        var motion = VolumeMotion(value: value)
        let initialFrame = motion.sample(at: clock())
        self.frame = initialFrame
        self.motion = motion
        target = initialFrame.volume
        observe(NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                center: workspaceCenter) { animator in
            if animator.reduceMotion() { animator.settle() }
        }
        observe(.NSProcessInfoPowerStateDidChange, center: systemCenter) { animator in
            animator.invalidateTimer()
            animator.startTimerIfNeeded()
        }
        observe(NSWorkspace.willSleepNotification, center: workspaceCenter) { _ in }
        observe(NSWorkspace.didWakeNotification, center: workspaceCenter) { _ in }
    }

    func setVolume(_ value: Double, animated: Bool = true) {
        guard !isStopped else { return }
        if isPublishing {
            pendingVolume = (value, animated)
            return
        }
        let next = min(1, max(0, value.isFinite ? value : 0))
        let immediate = !animated || isSleeping || reduceMotion()
        guard abs(next - target) > 0.000_001 || immediate && motion.isActive else { return }
        target = next
        let now = clock()
        motion.retarget(to: next, at: now, reducedMotion: immediate)
        publish(motion.sample(at: now))
        if motion.isActive { startTimerIfNeeded() } else { invalidateTimer() }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        lifecycle.invalidate()
        pendingVolume = nil
        invalidateTimer()
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        settle()
    }

    func handleLifecycleEvent(_ name: Notification.Name, at time: Double) {
        guard name == NSWorkspace.willSleepNotification || name == NSWorkspace.didWakeNotification else { return }
        guard !isStopped, lifecycle.acceptsEvent(at: time) else { return }
        if name == NSWorkspace.willSleepNotification {
            isSleeping = true
            settle()
        } else if name == NSWorkspace.didWakeNotification {
            isSleeping = false
        }
    }

    private func settle() {
        if isPublishing { pendingSettlement = true; return }
        let now = clock()
        motion.settle(at: now)
        invalidateTimer()
        publish(motion.sample(at: now))
    }

    func advanceFrame() {
        guard !isPublishing else { return }
        guard !isStopped, !isSleeping else { invalidateTimer(); return }
        if reduceMotion() { settle(); return }
        publish(motion.sample(at: clock()))
        if !motion.isActive { invalidateTimer() }
    }

    private func publish(_ next: VolumeMotionFrame) {
        guard next != frame else { return }
        isPublishing = true
        frame = next
        isPublishing = false
        // @Published sends before storing. A synchronous subscriber command
        // runs after this assignment, so it cannot be overwritten by this frame.
        drainCommands()
    }

    private func drainCommands() {
        guard !isDrainingCommands else { return }
        isDrainingCommands = true
        defer { isDrainingCommands = false }
        while pendingSettlement || pendingVolume != nil {
            if pendingSettlement {
                pendingSettlement = false
                settle()
            } else if let pending = pendingVolume {
                pendingVolume = nil
                setVolume(pending.value, animated: pending.animated)
            }
        }
    }

    private func startTimerIfNeeded() {
        guard timer == nil, motion.isActive, !isSleeping, !isStopped else { return }
        let rate = lowPowerMode() ? 30.0 : 60.0
        let timer = Timer(timeInterval: 1 / rate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceFrame() }
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
            let time = ProcessInfo.processInfo.systemUptime
            Task { @MainActor [weak self] in
                guard let self, !self.isStopped else { return }
                if name == NSWorkspace.willSleepNotification || name == NSWorkspace.didWakeNotification {
                    self.handleLifecycleEvent(name, at: time)
                } else {
                    handler(self)
                }
            }
        }
        observers.append((center, observer))
    }
}
