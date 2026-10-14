import AppKit
import Combine
import OrbitBarCore

@MainActor
private final class AnimationEnvironment {
    var time = 10.0
    var reduced = false
    var lowPower = false
    let workspace = NotificationCenter()
    let system = NotificationCenter()

    func animator(value: Double = 0.2) -> VolumeAnimator {
        VolumeAnimator(value: value, clock: { self.time }, reduceMotion: { self.reduced },
                       lowPowerMode: { self.lowPower }, workspaceCenter: workspace, systemCenter: system)
    }
}

/// Compile the production animator, including its Combine publisher and native
/// timer. Isolated clocks/notification centers never alter system audio/settings.
@main
private enum AnimationRegressions {
    @MainActor
    static func main() async throws {
        let environment = AnimationEnvironment()
        let animator = environment.animator()
        animator.setVolume(0.2)
        precondition(!animator.isAnimating, "Repeated readings must stay idle.")
        animator.setVolume(0.8)
        precondition(animator.isAnimating && animator.frame.volume == 0.2)
        environment.time = 10.08
        animator.advanceFrame()
        precondition(animator.frame.volume > 0.2 && animator.frame.volume < 0.8 && animator.frame.emphasis > 0)
        environment.time = 11
        animator.advanceFrame()
        precondition(animator.frame == VolumeMotionFrame(volume: 0.8, emphasis: 0) && !animator.isAnimating)

        animator.setVolume(0)
        environment.time = 11.04
        animator.advanceFrame()
        animator.setVolume(0.6, animated: false)
        precondition(animator.frame == VolumeMotionFrame(volume: 0.6, emphasis: 0) && !animator.isAnimating,
                     "Device changes must cancel an existing pulse and settle immediately.")

        animator.setVolume(1)
        environment.reduced = true
        environment.time = 11.05
        animator.advanceFrame()
        precondition(animator.frame == VolumeMotionFrame(volume: 1, emphasis: 0) && !animator.isAnimating,
                     "A frame must respect reduced motion before a delayed notification runs.")
        animator.setVolume(0.3)
        precondition(animator.frame.volume == 0.3 && !animator.isAnimating)
        environment.reduced = false
        animator.setVolume(0.9)
        environment.time = 11.1
        animator.advanceFrame()
        environment.reduced = true
        environment.workspace.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(10))
        precondition(animator.frame == VolumeMotionFrame(volume: 0.9, emphasis: 0) && !animator.isAnimating)

        environment.reduced = false
        animator.setVolume(0.1)
        let beforeRateChange = animator.frame
        precondition(animator.frameInterval == 1.0 / 60)
        environment.lowPower = true
        environment.system.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        try await Task.sleep(for: .milliseconds(10))
        precondition(animator.frameInterval == 1.0 / 30 && animator.frame == beforeRateChange,
                     "Changing frame rate must preserve the actual transition.")
        environment.lowPower = false
        environment.system.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        try await Task.sleep(for: .milliseconds(10))
        precondition(animator.frameInterval == 1.0 / 60)

        animator.handleLifecycleEvent(NSWorkspace.willSleepNotification, at: 20)
        precondition(animator.frame == VolumeMotionFrame(volume: 0.1, emphasis: 0) && !animator.isAnimating)
        animator.setVolume(0.4)
        precondition(animator.frame.volume == 0.4 && !animator.isAnimating)
        animator.handleLifecycleEvent(NSWorkspace.didWakeNotification, at: 21)
        animator.handleLifecycleEvent(NSWorkspace.willSleepNotification, at: 19)
        animator.setVolume(0.8)
        precondition(animator.isAnimating, "A delayed old sleep must not disable animations after waking.")
        animator.handleLifecycleEvent(.NSProcessInfoPowerStateDidChange, at: 100)
        animator.handleLifecycleEvent(NSWorkspace.willSleepNotification, at: 22)
        precondition(!animator.isAnimating, "Other notifications must not advance the sleep/wake watermark.")
        animator.handleLifecycleEvent(NSWorkspace.didWakeNotification, at: 23)
        animator.setVolume(0.2)
        environment.workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        environment.system.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        animator.stop()
        let stopped = animator.frame
        animator.setVolume(1)
        animator.advanceFrame()
        try await Task.sleep(for: .milliseconds(10))
        precondition(animator.frame == stopped && !animator.isAnimating,
                     "Stop must reject future targets and already queued notification callbacks.")

        let reentrantEnvironment = AnimationEnvironment()
        let reentrant = reentrantEnvironment.animator()
        var redirected = false
        let redirectSubscription = reentrant.$frame.dropFirst().sink { next in
            if !redirected && next.volume > 0.2 {
                redirected = true
                reentrant.setVolume(0, animated: false)
            }
        }
        reentrant.setVolume(1)
        reentrantEnvironment.time = 10.08
        reentrant.advanceFrame()
        precondition(redirected && reentrant.frame == VolumeMotionFrame(volume: 0, emphasis: 0) && !reentrant.isAnimating,
                     "A synchronous publisher command must not be overwritten by the outer old frame.")
        redirectSubscription.cancel()
        reentrant.stop()

        let stoppingEnvironment = AnimationEnvironment()
        let stopping = stoppingEnvironment.animator()
        var stoppedInsidePublish = false
        let stopSubscription = stopping.$frame.dropFirst().sink { next in
            if !stoppedInsidePublish && next.volume > 0.2 {
                stoppedInsidePublish = true
                stopping.stop()
            }
        }
        stopping.setVolume(1)
        stoppingEnvironment.time = 10.08
        stopping.advanceFrame()
        precondition(stoppedInsidePublish && stopping.frame == VolumeMotionFrame(volume: 1, emphasis: 0) && !stopping.isAnimating,
                     "Stopping during publication must commit the final target after the outer frame.")
        stopping.setVolume(0)
        precondition(stopping.frame.volume == 1 && !stopping.isAnimating)
        stopSubscription.cancel()
        let sleepingEnvironment = AnimationEnvironment()
        let sleeping = sleepingEnvironment.animator()
        var sleptInsidePublish = false
        let sleepSubscription = sleeping.$frame.dropFirst().sink { next in
            if !sleptInsidePublish && next.volume > 0.2 {
                sleptInsidePublish = true
                sleeping.handleLifecycleEvent(NSWorkspace.willSleepNotification, at: 1)
                sleeping.advanceFrame()
            }
        }
        sleeping.setVolume(1)
        sleepingEnvironment.time = 10.08
        sleeping.advanceFrame()
        precondition(sleptInsidePublish && sleeping.frame == VolumeMotionFrame(volume: 1, emphasis: 0) && !sleeping.isAnimating,
                     "Sleep settlement and nested sampling must wait for the outer publication to commit.")
        sleeping.setVolume(0.4)
        precondition(sleeping.frame.volume == 0.4 && !sleeping.isAnimating)
        sleepSubscription.cancel()
        sleeping.stop()

        let restartingEnvironment = AnimationEnvironment()
        let restarting = restartingEnvironment.animator()
        var restarted = false
        let restartSubscription = restarting.$frame.dropFirst().sink { next in
            if !restarted && next.volume == 1 {
                restarted = true
                restartingEnvironment.reduced = false
                restarting.setVolume(0)
            }
        }
        restarting.setVolume(1)
        restartingEnvironment.reduced = true
        restarting.advanceFrame()
        precondition(restarted && restarting.isAnimating && restarting.frame.volume == 1,
                     "A settlement subscriber's new target must keep its new timer.")
        restartingEnvironment.time = 11
        restarting.advanceFrame()
        precondition(restarting.frame == VolumeMotionFrame(volume: 0, emphasis: 0) && !restarting.isAnimating)
        restartSubscription.cancel()
        restarting.stop()

        let wakingEnvironment = AnimationEnvironment()
        let waking = wakingEnvironment.animator()
        var wokeInsideSettlement = false
        let wakeSubscription = waking.$frame.dropFirst().sink { next in
            if !wokeInsideSettlement && next.volume == 1 {
                wokeInsideSettlement = true
                waking.handleLifecycleEvent(NSWorkspace.didWakeNotification, at: 2)
                waking.setVolume(0)
            }
        }
        waking.setVolume(1)
        waking.handleLifecycleEvent(NSWorkspace.willSleepNotification, at: 1)
        precondition(wokeInsideSettlement && waking.isAnimating,
                     "A wake and new target during sleep settlement must resume the new timer.")
        wakingEnvironment.time = 11
        waking.advanceFrame()
        precondition(waking.frame == VolumeMotionFrame(volume: 0, emphasis: 0) && !waking.isAnimating)
        wakeSubscription.cancel()
        waking.stop()
        print("Native animation regressions passed: idle timers, exact settlement, device reset, reduced motion, 60/30 fps, sleep ordering, terminal stop, publisher retarget/stop/sleep reentry and restart after settlement.")
    }
}
