import AppKit
import OrbitBarCore
import SwiftUI

@MainActor
final class PopoverLayout: ObservableObject {
    @Published private(set) var screenHeight: CGFloat = 800
    func update(screenHeight: CGFloat) {
        guard screenHeight.isFinite, screenHeight > 0, self.screenHeight != screenHeight else { return }
        self.screenHeight = screenHeight
    }
}

private struct PopoverContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

@MainActor
struct OrbitPopoverView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var monitor: StatusMonitor
    @ObservedObject var settings: AppSettings
    let animator: VolumeAnimator
    let bluetoothMonitor: BluetoothMonitor
    @ObservedObject var layout: PopoverLayout
    @State private var showsSettings = false
    @State private var sliderVolume = 0.0
    @State private var isAdjustingVolume = false
    @State private var dragDeviceID: UInt32?
    @State private var dragOutputIdentifier: String?
    @State private var dragIsInvalidated = false
    @State private var measuredContentHeight: CGFloat = 0

    init(monitor: StatusMonitor, settings: AppSettings, animator: VolumeAnimator, bluetoothMonitor: BluetoothMonitor,
         layout: PopoverLayout) {
        self.monitor = monitor
        self.settings = settings
        self.animator = animator
        self.bluetoothMonitor = bluetoothMonitor
        self.layout = layout
    }

    private var battery: BatteryState { monitor.snapshot.battery }
    private var network: NetworkState { monitor.snapshot.network }
    private var audio: AudioState { monitor.snapshot.audio }
    private var bluetooth: BluetoothState { monitor.snapshot.bluetooth }
    private var activeBluetoothDevice: BluetoothDeviceState? {
        BluetoothOutputMatcher.currentDevice(audio: audio, devices: bluetooth.devices)
    }

    private var viewportHeight: CGFloat {
        let available = layout.screenHeight - 150
        let estimate = CGFloat(470 + min(bluetooth.connectedCount, 5) * 66 + (showsSettings ? 330 : 0))
        let content = measuredContentHeight > 0 ? measuredContentHeight + 2 : estimate
        return max(160, min(content, available, 650))
    }

    var body: some View {
        VStack(spacing: 14) {
            header

            ScrollView {
                VStack(spacing: 14) {
                    VStack(spacing: 0) {
                        batteryPanel
                        panelDivider
                        networkRow
                        panelDivider
                        audioPanel
                        panelDivider
                        bluetoothPanel
                    }
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(.primary.opacity(0.055), lineWidth: 1)
                    }
                    if showsSettings { appearanceSettings }
                }
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: PopoverContentHeightKey.self, value: proxy.size.height)
                    }
                }
            }
            .frame(height: viewportHeight)
            .onPreferenceChange(PopoverContentHeightKey.self) { height in
                Task { @MainActor in
                    if height.isFinite, height > 0, abs(height - measuredContentHeight) > 0.5 {
                        measuredContentHeight = height
                    }
                }
            }

            footer
        }
        .padding(16)
        .frame(width: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            resetVolumeDrag()
            settings.refreshLoginStatus()
        }
        .onDisappear { resetVolumeDrag() }
        .onChange(of: audio.volume) { _, newVolume in
            if !isAdjustingVolume { sliderVolume = newVolume }
        }
        .onChange(of: audio.outputIdentifier) { _, _ in invalidateVolumeDrag() }
        .onChange(of: audio.outputDeviceID) { _, _ in invalidateVolumeDrag() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            StatusGlyphView(snapshot: monitor.snapshot, settings: settings,
                            dark: colorScheme == .dark, size: 40, animator: animator)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("OrbitBar")
                    .font(.system(size: 18, weight: .semibold))
                Text("电量 · 网络 · 蓝牙 · 音量")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                monitor.refresh()
                bluetoothMonitor.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.borderless)
            .help("刷新系统状态")
            .accessibilityLabel("刷新系统状态")
        }
    }

    private var batteryPanel: some View {
        HStack(spacing: 14) {
            orbitGauge

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(batteryTitle)
                        .font(.system(size: battery.percent == nil ? 24 : 34, weight: .semibold, design: .rounded))
                        .monospacedDigit()

                    if battery.isPresent, battery.percent != nil {
                        Text("%")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel(batteryAccessibilityLabel)

                Text(batteryStatus)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)

                if let detail = batteryDetail {
                    Text(detail)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 6) {
                settingsShortcut(.battery)
                if battery.isLowPowerMode {
                    Image(systemName: "leaf.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.yellow)
                        .help("低电量模式已开启")
                        .accessibilityLabel("低电量模式已开启")
                }
            }
        }
        .padding(16)
    }

    private var orbitGauge: some View {
        StatusGlyphView(snapshot: monitor.snapshot, settings: settings,
                        dark: colorScheme == .dark, size: 96, animator: animator)
    }

    private var networkRow: some View {
        HStack(spacing: 10) {
            sectionIcon(networkSymbol)

            VStack(alignment: .leading, spacing: 3) {
                Text(networkTitle)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                Text(networkDetail)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)
            settingsShortcut(.network)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .accessibilityElement(children: .contain)
    }

    private var audioPanel: some View {
        let presentedDeviceID = audio.outputDeviceID
        let presentedOutputIdentifier = audio.outputIdentifier
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                sectionIcon(audio.outputKind.symbolName)

                VStack(alignment: .leading, spacing: 3) {
                    Text(audio.outputKind.displayName)
                        .font(.system(size: 15, weight: .medium))
                    Text(audio.outputKind == .unavailable ? "等待系统选择可用输出" : audio.outputName)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if audio.outputKind.isBluetooth {
                        Text(activeBluetoothDevice?.batteryStatusText ?? "设备电量暂不可用")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 4)

                if audio.canSetVolume {
                    Text(audio.isMuted ? "静音" : "音量 \(Int((displayedVolume * 100).rounded()))%")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                settingsShortcut(.sound)
            }

            if audio.canSetVolume || audio.canSetMute {
                HStack(spacing: 9) {
                    Button {
                        guard let deviceID = presentedDeviceID else { return }
                        monitor.toggleMute(expectedDeviceID: deviceID, expectedOutputIdentifier: presentedOutputIdentifier)
                    } label: {
                        Image(systemName: audio.isMuted ? "speaker.slash.fill" : "speaker.fill")
                            .font(.system(size: 14))
                            .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.borderless)
                    .help(audio.isMuted ? "取消静音" : "静音")
                    .accessibilityLabel(audio.isMuted ? "取消静音" : "静音")
                    .disabled(!audio.canSetMute)

                    if audio.canSetVolume {
                    Slider(value: Binding(
                        get: { displayedVolume },
                        set: { value in
                            guard !dragIsInvalidated, let deviceID = isAdjustingVolume ? dragDeviceID : presentedDeviceID else { return }
                            sliderVolume = value
                            let identifier = isAdjustingVolume ? dragOutputIdentifier : presentedOutputIdentifier
                            if !monitor.setVolume(value, expectedDeviceID: deviceID, expectedOutputIdentifier: identifier) {
                                sliderVolume = audio.volume
                                if isAdjustingVolume { dragIsInvalidated = true }
                            }
                        }
                    ), in: 0...1) { isEditing in
                        isAdjustingVolume = isEditing
                        if isEditing {
                            dragDeviceID = presentedDeviceID
                            dragOutputIdentifier = presentedOutputIdentifier
                            dragIsInvalidated = false
                        } else {
                            sliderVolume = audio.volume
                            dragDeviceID = nil
                            dragOutputIdentifier = nil
                            dragIsInvalidated = false
                        }
                    }
                    .controlSize(.large)
                    .accessibilityLabel("输出音量")
                    .accessibilityValue("\(Int((displayedVolume * 100).rounded()))%")
                    .onDisappear { resetVolumeDrag() }

                    Image(systemName: "speaker.wave.3.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    } else {
                        Text("音量由输出设备控制")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            } else {
                Text(audio.outputKind == .unavailable ? "暂无可用输出设备" : "当前输出无法在此调节音量")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var bluetoothPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                BluetoothSymbol()
                    .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .frame(width: 13, height: 22)
                    .frame(width: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("蓝牙设备").font(.system(size: 15, weight: .medium))
                    Text(bluetooth.summary).font(.system(size: 14)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                settingsShortcut(.bluetooth)
            }
            if bluetooth.authorization == .notDetermined {
                Button("允许显示蓝牙设备") { bluetoothMonitor.requestAccess() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .padding(.leading, 46)
            } else if bluetooth.authorization == .denied {
                Button("打开蓝牙权限设置") { SystemSettingsDestination.bluetoothPrivacy.open() }
                    .buttonStyle(.bordered)
                    .padding(.leading, 46)
            }
            ForEach(bluetooth.devices) { device in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: device.kind.symbolName)
                        .font(.system(size: 17)).frame(width: 36, height: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(device.name).font(.system(size: 14, weight: .medium)).lineLimit(1).help(device.name)
                            if isCurrentBluetoothOutput(device) {
                                Text("正在使用").font(.system(size: 11, weight: .medium))
                                    .fixedSize()
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                    .background(.green.opacity(0.10), in: Capsule())
                            }
                        }
                        Text(device.batteryStatusText)
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private func isCurrentBluetoothOutput(_ device: BluetoothDeviceState) -> Bool {
        guard audio.outputKind.isBluetooth else { return false }
        return BluetoothOutputMatcher.isCurrent(device, audio: audio, devices: bluetooth.devices)
    }

    private func invalidateVolumeDrag() {
        sliderVolume = audio.volume
        if isAdjustingVolume { dragIsInvalidated = true }
    }

    private func resetVolumeDrag() {
        isAdjustingVolume = false
        dragDeviceID = nil
        dragOutputIdentifier = nil
        dragIsInvalidated = false
        sliderVolume = audio.volume
    }

    private var appearanceSettings: some View {
        VStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("菜单栏外观")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)

                Toggle("按电量显示颜色", isOn: $settings.useStatusColors)
                Toggle("显示电量百分比", isOn: $settings.showBatteryPercentage)

                HStack(spacing: 14) {
                    MenuBarGlyphPreview(snapshot: monitor.snapshot, settings: settings,
                                        dark: colorScheme == .dark, animator: animator)
                        .frame(width: MenuBarIconView.requiredWidth(buttonHeight: 48, scale: settings.iconScale,
                                                                     percentage: nil, accessory: StatusAccessory(snapshot: monitor.snapshot)),
                               height: 48)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 5) {
                        settingSlider("图标宽度", value: $settings.iconScale, range: 0.65...1.6,
                                      step: 0.05, detail: "\(Int((settings.iconScale * 100).rounded()))%")
                        Text("实时预览 · 更宽更清晰")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }

                settingSlider("圆环粗细", value: $settings.ringThickness, range: 1.5...4.2,
                              step: 0.05, detail: String(format: "%.2f pt", settings.ringThickness))

                Divider()

                Toggle("登录时启动", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                ))

                if let loginError = settings.loginError {
                    Text(loginError)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
        .font(.system(size: 15))
        .toggleStyle(.switch)
        .controlSize(.large)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var footer: some View {
        HStack {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { showsSettings.toggle() }
            } label: {
                Label(showsSettings ? "收起设置" : "设置", systemImage: "slider.horizontal.3")
                    .font(.system(size: 14))
            }
            .buttonStyle(.borderless)
            .accessibilityValue(showsSettings ? "已展开" : "已收起")

            Spacer()

            Button("退出") {
                monitor.stop()
                NSApplication.shared.terminate(nil)
            }
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .buttonStyle(.borderless)
            .help("退出 OrbitBar")
        }
        .padding(.horizontal, 2)
    }

    private var panelDivider: some View {
        Divider().padding(.horizontal, 16)
    }

    private func sectionIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.primary)
            .frame(width: 36)
            .accessibilityHidden(true)
    }

    private func settingsShortcut(_ destination: SystemSettingsDestination) -> some View {
        Button {
            destination.open()
        } label: {
            Image(systemName: "arrow.up.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("打开\(destination.title)设置")
        .accessibilityLabel("打开\(destination.title)设置")
    }

    private func settingSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                               step: Double, detail: String) -> some View {
        VStack(spacing: 7) {
            HStack {
                Text(title)
                Spacer()
                Text(detail)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
                .controlSize(.large)
                .accessibilityLabel(title)
                .accessibilityValue(detail)
        }
    }

    private var displayedVolume: Double { isAdjustingVolume && !dragIsInvalidated ? sliderVolume : audio.volume }

    private var batteryTitle: String {
        guard battery.isPresent else { return battery.isExternalPower ? "外接电源" : "电池未知" }
        return battery.percent.map(String.init) ?? "—"
    }

    private var batteryStatus: String {
        guard battery.isPresent else { return "未检测到内置电池" }
        if battery.isCharging { return "正在充电" }
        if battery.isExternalPower { return battery.percent == 100 ? "电池已充满 · 已接通电源" : "已接通电源" }
        if battery.percent == nil { return "电池电量暂不可用" }
        return battery.isLowPowerMode ? "使用电池 · 低电量模式" : "使用电池"
    }

    private var batteryDetail: String? {
        if let minutes = battery.minutesRemaining, minutes > 0, battery.isPresent,
           battery.isCharging || !battery.isExternalPower {
            let duration = minutes < 60 ? "\(minutes) 分钟" : "\(minutes / 60) 小时\(minutes % 60 == 0 ? "" : " \(minutes % 60) 分钟")"
            return battery.isCharging ? "预计 \(duration)充满" : "预计可用 \(duration)"
        }
        if let health = battery.healthPercent, battery.isPresent {
            if let cycles = battery.cycleCount { return "健康度 \(health)% · \(cycles) 次循环" }
            return "电池健康度 \(health)%"
        }
        return nil
    }

    private var batteryAccessibilityLabel: String {
        if let percent = battery.percent, battery.isPresent { return "电池电量 \(percent)%" }
        return battery.isPresent ? "电池电量暂不可用" : "未检测到内置电池"
    }

    private var networkSymbol: String {
        switch network.kind {
        case .wifi: return "wifi"
        case .ethernet: return "network"
        case .offline: return "wifi.slash"
        case .other: return "globe"
        }
    }

    private var networkTitle: String {
        switch network.kind {
        case .wifi: return network.name ?? "Wi-Fi 已连接"
        case .ethernet: return "有线网络"
        case .offline: return "网络未连接"
        case .other: return "网络已连接"
        }
    }

    private var networkDetail: String {
        switch network.kind {
        case .wifi:
            switch network.signalLevel {
            case 3: return "Wi-Fi · 信号强"
            case 2: return "Wi-Fi · 信号良好"
            case 1: return "Wi-Fi · 信号较弱"
            default: return "Wi-Fi · 信号强度暂不可用"
            }
        case .ethernet: return "通过以太网连接"
        case .offline: return "打开系统设置连接网络"
        case .other: return "通过其他网络接口连接"
        }
    }
}

private enum SystemSettingsDestination {
    case battery, network, sound, bluetooth, bluetoothPrivacy

    var title: String {
        switch self {
        case .battery: return "电池"
        case .network: return "网络"
        case .sound: return "声音"
        case .bluetooth: return "蓝牙"
        case .bluetoothPrivacy: return "蓝牙权限"
        }
    }

    private var paneID: String {
        switch self {
        case .battery: return "com.apple.Battery-Settings.extension"
        case .network: return "com.apple.Network-Settings.extension"
        case .sound: return "com.apple.Sound-Settings.extension"
        case .bluetooth: return "com.apple.BluetoothSettings"
        case .bluetoothPrivacy: return "com.apple.preference.security?Privacy_Bluetooth"
        }
    }

    @MainActor
    func open() {
        guard let url = URL(string: "x-apple.systempreferences:\(paneID)") else { return }
        NSWorkspace.shared.open(url)
    }
}
