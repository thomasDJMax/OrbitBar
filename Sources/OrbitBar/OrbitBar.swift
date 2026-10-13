import AppKit
import SwiftUI
import Combine
import OrbitBarCore

@main
enum OrbitBarApplication {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = OrbitBarDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class OrbitBarDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let settings = AppSettings()
    private let monitor = StatusMonitor()
    private lazy var bluetoothMonitor = BluetoothMonitor()
    private lazy var bluetoothOutputBridge = BluetoothOutputBridge(
        readCurrentAudio: { [weak self] in self?.monitor.snapshot.audio ?? .init() },
        refreshBluetooth: { [weak self] audio in self?.bluetoothMonitor.currentAudioOutputDidChange(audio) })
    private lazy var animator = VolumeAnimator(value: effectiveVolume(monitor.snapshot))
    private var statusItem: NSStatusItem?
    private let menuBarIcon = MenuBarIconView(frame: .zero)
    private let popover = NSPopover()
    private let popoverLayout = PopoverLayout()
    private var subscriptions = Set<AnyCancellable>()
    private var instanceLock: FileHandle?
    private var appearanceObservation: NSKeyValueObservation?
    private var animatedOutputIdentifier: String?
    private static let reopenNotification = Notification.Name("com.thomas.OrbitBar.showPanel")

    func applicationDidFinishLaunching(_ notification: Notification) {
        switch acquireInstanceLock() {
        case .acquired: break
        case .alreadyRunning:
            DistributedNotificationCenter.default().postNotificationName(Self.reopenNotification,
                                                                         object: nil, userInfo: nil, deliverImmediately: true)
            NSApp.terminate(nil)
            return
        case .failed(let reason):
            let alert = NSAlert()
            alert.messageText = "OrbitBar 无法启动"
            alert.informativeText = "无法建立应用运行锁：\(reason)"
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(reopenExistingInstance(_:)),
                                                             name: Self.reopenNotification, object: nil)
        for name in [NSApplication.didChangeScreenParametersNotification, NSWindow.didChangeScreenNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(screenChanged(_:)), name: name, object: nil)
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.autosaveName = "OrbitBar"
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(clicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.image = nil
        button.title = ""
        menuBarIcon.frame = button.bounds
        menuBarIcon.autoresizingMask = [.width, .height]
        menuBarIcon.setAccessibilityElement(false)
        button.addSubview(menuBarIcon)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        updatePopoverLayout()
        popover.contentViewController = NSHostingController(rootView: OrbitPopoverView(monitor: monitor, settings: settings,
                                                                                     animator: animator, bluetoothMonitor: bluetoothMonitor,
                                                                                     layout: popoverLayout))
        bluetoothMonitor.$state
            .sink { [weak self] state in self?.monitor.updateBluetooth(state) }
            .store(in: &subscriptions)
        monitor.$snapshot
            // StatusMonitor publishes on MainActor. Do not schedule into the default
            // run-loop mode: that can postpone a slider's live updates until release.
            .sink { [weak self] snapshot in self?.handleSnapshotChange(snapshot) }
            .store(in: &subscriptions)
        monitor.onAudioOutputChange = { [weak self] audio in
            self?.bluetoothOutputBridge.outputDidChange(audio)
        }
        bluetoothOutputBridge.outputDidChange(monitor.snapshot.audio)
        animator.$frame
            .sink { [weak self] frame in self?.updateAnimationFrame(frame) }
            .store(in: &subscriptions)
        settings.onAppearanceChange = { [weak self] in self?.updateIcon() }
        appearanceObservation = button.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.updateIcon() }
        }
        updateIcon()
        let defaults = UserDefaults.standard
        if ProcessInfo.processInfo.arguments.contains("--show-panel") || !defaults.bool(forKey: "hasSeenPanel") {
            defaults.set(true, forKey: "hasSeenPanel")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showPopover() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return true
    }

    private enum InstanceLockResult { case acquired, alreadyRunning, failed(String) }

    private func acquireInstanceLock() -> InstanceLockResult {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OrbitBar", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let path = directory.appendingPathComponent("instance.lock").path
            let descriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { return .failed(NSError(domain: NSPOSIXErrorDomain, code: Int(errno)).localizedDescription) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let failure = errno
                close(descriptor)
                return failure == EWOULDBLOCK ? .alreadyRunning
                    : .failed(NSError(domain: NSPOSIXErrorDomain, code: Int(failure)).localizedDescription)
            }
            instanceLock = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        } catch { return .failed(error.localizedDescription) }
        return .acquired
    }

    @objc private func reopenExistingInstance(_ notification: Notification) { showPopover() }

    @objc private func screenChanged(_ notification: Notification) { updatePopoverLayout() }

    private func updatePopoverLayout() {
        let screen = statusItem?.button?.window?.screen
            ?? popover.contentViewController?.view.window?.screen ?? NSScreen.main
        popoverLayout.update(screenHeight: screen?.visibleFrame.height ?? 800)
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu(sender)
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        updatePopoverLayout()
        monitor.refresh()
        bluetoothMonitor.refresh()
        settings.refreshLoginStatus()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showContextMenu(_ button: NSStatusBarButton) {
        popover.performClose(nil)
        let menu = NSMenu()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        menu.addItem(withTitle: version.map { "OrbitBar \($0)" } ?? "OrbitBar", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        let show = menu.addItem(withTitle: "查看状态", action: #selector(openPanel), keyEquivalent: "")
        show.target = self
        let quit = menu.addItem(withTitle: "退出 OrbitBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        statusItem?.menu = menu
        button.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func openPanel() { showPopover() }

    private func effectiveVolume(_ snapshot: SystemSnapshot) -> Double {
        snapshot.audio.isMuted ? 0 : snapshot.audio.volume
    }

    private func handleSnapshotChange(_ snapshot: SystemSnapshot) {
        // @Published emits before its stored value changes, so use the delivered state.
        updateIcon(snapshotOverride: snapshot)
        let routeChanged = snapshot.audio.outputIdentifier != animatedOutputIdentifier
        animatedOutputIdentifier = snapshot.audio.outputIdentifier
        animator.setVolume(effectiveVolume(snapshot), animated: !routeChanged && snapshot.audio.outputKind != .unavailable)
    }

    private func updateAnimationFrame(_ frame: VolumeMotionFrame) {
        // A frame changes only four tiny vector dots, never the background bitmap
        // or status-item layout, network reads, text, or accessibility labels.
        menuBarIcon.volume = frame.volume
        menuBarIcon.volumeEmphasis = frame.emphasis
    }

    private func updateIcon(snapshotOverride: SystemSnapshot? = nil) {
        guard let button = statusItem?.button else { return }
        let snapshot = snapshotOverride ?? monitor.snapshot
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let key = IconRenderer.backgroundKey(snapshot: snapshot, settings: settings, dark: dark, canvasSize: 64)
        if menuBarIcon.backgroundKey != key {
            let image = IconRenderer.image(snapshot: snapshot, settings: settings, dark: dark,
                                           canvasSize: 64, drawVolumeDots: false).copy() as! NSImage
            image.size = NSSize(width: 32, height: 32)
            menuBarIcon.image = image
            menuBarIcon.backgroundKey = key
        }
        let percentage = settings.showBatteryPercentage ? snapshot.battery.percent.map { "\($0)%" } : nil
        menuBarIcon.iconScale = settings.iconScale
        menuBarIcon.percentage = percentage
        menuBarIcon.accessory = StatusAccessory(snapshot: snapshot)
        menuBarIcon.foregroundColor = dark ? .white : NSColor(white: 0.12, alpha: 1)
        let buttonHeight = button.bounds.height > 0 ? button.bounds.height : NSStatusBar.system.thickness
        let length = MenuBarIconView.requiredWidth(buttonHeight: buttonHeight, scale: settings.iconScale,
                                                   percentage: percentage, accessory: menuBarIcon.accessory)
        if statusItem?.length != length { statusItem?.length = length }
        let battery: String
        if !snapshot.battery.isPresent { battery = "未检测到内置电池" }
        else if let percent = snapshot.battery.percent { battery = "电量 \(percent)%" }
        else { battery = "电量暂不可用" }
        let network = snapshot.network.kind == .offline ? "网络未连接" : snapshot.network.name ?? "网络已连接"
        let audio = snapshot.audio.isMuted ? "已静音" : snapshot.audio.canSetVolume
            ? "音量 \(Int(snapshot.audio.volume * 100))%" : "音量由输出设备控制"
        let output = snapshot.audio.outputKind == .unavailable ? "暂无可用输出设备"
            : "\(snapshot.audio.outputKind.displayName)：\(snapshot.audio.outputName)"
        let device = BluetoothOutputMatcher.currentDevice(audio: snapshot.audio, devices: snapshot.bluetooth.devices)
        let peripheral = device.map { " · \($0.batteryStatusText)" } ?? ""
        button.toolTip = "OrbitBar · \(battery) · \(network) · \(audio) · \(output)\(peripheral) · \(snapshot.bluetooth.summary)"
        button.setAccessibilityLabel("OrbitBar，\(battery)，\(network)，\(audio)，\(output)\(peripheral)，\(snapshot.bluetooth.summary)，点击查看详情")
    }

    func applicationWillTerminate(_ notification: Notification) {
        settings.flushPendingAppearanceChanges()
        bluetoothOutputBridge.stop()
        animator.stop()
        monitor.stop()
        bluetoothMonitor.stop()
        DistributedNotificationCenter.default().removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        instanceLock?.closeFile()
    }
}
