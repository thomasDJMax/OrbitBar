import AppKit
import Combine
import ServiceManagement
import OrbitBarCore
import CoreFoundation

@MainActor
final class AppSettings: ObservableObject {
    @MainActor
    struct LoginService {
        var status: () -> SMAppService.Status
        var register: () throws -> Void
        var unregister: () throws -> Void

        static var system: LoginService {
            LoginService(status: { SMAppService.mainApp.status },
                         register: { try SMAppService.mainApp.register() },
                         unregister: { try SMAppService.mainApp.unregister() })
        }
    }

    @Published var useStatusColors: Bool {
        didSet { if useStatusColors != oldValue { appearanceDidChange() } }
    }
    @Published var showBatteryPercentage: Bool {
        didSet { if showBatteryPercentage != oldValue { appearanceDidChange() } }
    }
    @Published var iconScale: Double {
        didSet {
            guard !normalizingIconScale else { return }
            let normalized = AppearancePreferences.normalizedIconScale(iconScale, fallback: oldValue)
            if iconScale != normalized {
                // A wrapped @Published assignment re-enters didSet. Normalize
                // once, then notify using the original valid previous value.
                normalizingIconScale = true
                iconScale = normalized
                normalizingIconScale = false
            }
            if iconScale != oldValue { appearanceDidChange() }
        }
    }
    @Published var ringThickness: Double {
        didSet {
            guard !normalizingRingThickness else { return }
            let normalized = AppearancePreferences.normalizedRingThickness(ringThickness, fallback: oldValue)
            if ringThickness != normalized {
                normalizingRingThickness = true
                ringThickness = normalized
                normalizingRingThickness = false
            }
            if ringThickness != oldValue { appearanceDidChange() }
        }
    }
    @Published private(set) var launchAtLogin: Bool
    @Published private(set) var loginError: String?
    /// Fired immediately for visual changes, including while a native slider is tracking.
    var onAppearanceChange: (() -> Void)?
    private let defaults: UserDefaults
    private let loginService: LoginService
    private var normalizingIconScale = false
    private var normalizingRingThickness = false
    private var persistenceTask: Task<Void, Never>?
    private var hasPendingAppearanceChanges = false
    private var lastLoginStatus: SMAppService.Status
    private var loginOperationError: String?
    private static let approvalMessage = "请在系统设置 → 通用 → 登录项中允许 OrbitBar。"

    init(defaults: UserDefaults = .standard, loginService: LoginService = .system) {
        self.defaults = defaults
        self.loginService = loginService
        defaults.register(defaults: ["useStatusColors": true, "showBatteryPercentage": false,
                                     "iconScale": AppearancePreferences.defaultIconScale,
                                     "ringThickness": AppearancePreferences.defaultRingThickness])
        useStatusColors = Self.storedBoolean(defaults.object(forKey: "useStatusColors"), fallback: true)
        showBatteryPercentage = Self.storedBoolean(defaults.object(forKey: "showBatteryPercentage"), fallback: false)
        iconScale = AppearancePreferences.normalizedIconScale(
            AppearancePreferences.storedNumber(defaults.object(forKey: "iconScale")))
        ringThickness = AppearancePreferences.normalizedRingThickness(
            AppearancePreferences.storedNumber(defaults.object(forKey: "ringThickness")))
        let loginStatus = loginService.status()
        lastLoginStatus = loginStatus
        launchAtLogin = loginStatus == .enabled
        loginError = loginStatus == .requiresApproval ? Self.approvalMessage : nil
    }

    private static func storedBoolean(_ object: Any?, fallback: Bool) -> Bool {
        guard let number = object as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return fallback }
        return number.boolValue
    }

    private func appearanceDidChange() {
        onAppearanceChange?()
        hasPendingAppearanceChanges = true
        persistenceTask?.cancel()
        persistenceTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.flushPendingAppearanceChanges()
        }
    }

    /// Also called on termination so a slider's final change is always persisted.
    func flushPendingAppearanceChanges() {
        persistenceTask?.cancel()
        persistenceTask = nil
        guard hasPendingAppearanceChanges else { return }
        hasPendingAppearanceChanges = false
        defaults.set(useStatusColors, forKey: "useStatusColors")
        defaults.set(showBatteryPercentage, forKey: "showBatteryPercentage")
        defaults.set(iconScale, forKey: "iconScale")
        defaults.set(ringThickness, forKey: "ringThickness")
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        // A user retry clears the previous operation's error; a passive panel
        // refresh retains it until macOS actually reports a different status.
        loginOperationError = nil
        do {
            let status = loginService.status()
            if enabled {
                if status != .enabled && status != .requiresApproval { try loginService.register() }
            } else if status != .notRegistered {
                try loginService.unregister()
            }
            refreshLoginStatus()
        } catch {
            refreshLoginStatus()
            let message = "无法更新登录项：\(error.localizedDescription)"
            loginOperationError = message
            loginError = lastLoginStatus == .requiresApproval ? "\(message)\n\(Self.approvalMessage)" : message
        }
    }

    func refreshLoginStatus() {
        let status = loginService.status()
        if status != lastLoginStatus {
            lastLoginStatus = status
            loginOperationError = nil
        }
        let enabled = status == .enabled
        let approval = status == .requiresApproval ? Self.approvalMessage : nil
        let error = loginOperationError.map { message in
            approval.map { "\(message)\n\($0)" } ?? message
        } ?? approval
        if launchAtLogin != enabled { launchAtLogin = enabled }
        if loginError != error { loginError = error }
    }
}
