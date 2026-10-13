// Standalone regressions compile the actual AppSettings with isolated UUID
// defaults domains and a fake login service. No app or system login item is used.
import Foundation
import ServiceManagement

@main
private enum AppSettingsRegressions {
    @MainActor
    static func main() async throws {
        var status: SMAppService.Status = .notRegistered
        var registerCalls = 0
        let fakeService = AppSettings.LoginService(
            status: { status }, register: { registerCalls += 1; status = .enabled },
            unregister: { throw NSError(domain: "SettingsTest", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: "Test unregister failed"]) })

        guard let domainBase = ProcessInfo.processInfo.environment["ORBITBAR_SETTINGS_TEST_DOMAIN"],
              domainBase.hasPrefix("com.thomas.OrbitBar.settings-regression.") else {
            fatalError("Run this regression through scripts/test-settings.sh to guarantee isolated-domain cleanup.")
        }
        let corruptDomain = "\(domainBase).corrupt"
        let savedDomain = "\(domainBase).saved"
        let corrupt = UserDefaults(suiteName: corruptDomain)!
        let defaults = UserDefaults(suiteName: savedDomain)!
        defer {
            corrupt.removePersistentDomain(forName: corruptDomain)
            defaults.removePersistentDomain(forName: savedDomain)
        }
        corrupt.setPersistentDomain(["useStatusColors": "false", "showBatteryPercentage": 2,
                                     "iconScale": "1.1", "ringThickness": "bad"], forName: corruptDomain)
        let repaired = AppSettings(defaults: corrupt, loginService: fakeService)
        precondition(repaired.useStatusColors && !repaired.showBatteryPercentage,
                     "Corrupt boolean preferences must use defaults, not coerce strings/numbers.")
        precondition(repaired.iconScale == 1.6 && repaired.ringThickness == 3.3)
        precondition(corrupt.persistentDomain(forName: corruptDomain)?["iconScale"] as? String == "1.1",
                     "Initialization must not overwrite user preferences.")

        defaults.setPersistentDomain(["useStatusColors": false, "showBatteryPercentage": true,
                                      "iconScale": 0.95, "ringThickness": 2.2], forName: savedDomain)
        let settings = AppSettings(defaults: defaults, loginService: fakeService)
        precondition(!settings.useStatusColors && settings.showBatteryPercentage)
        precondition(settings.iconScale == 0.95 && settings.ringThickness == 2.2)
        var callbacks = 0
        settings.onAppearanceChange = { callbacks += 1 }
        settings.iconScale = 0.95
        settings.iconScale = .nan
        settings.ringThickness = .infinity
        precondition(callbacks == 0 && settings.iconScale == 0.95)
        precondition(settings.ringThickness == 2.2)

        settings.iconScale = 1.0
        settings.iconScale = 1.1
        settings.iconScale = 1.2
        precondition(callbacks == 3 && defaults.double(forKey: "iconScale") == 0.95,
                     "Visual feedback must be immediate without a disk write per slider event.")
        try await Task.sleep(for: .milliseconds(400))
        precondition(defaults.double(forKey: "iconScale") == 1.2,
                     "The last slider value should persist in one coalesced settings batch.")
        settings.ringThickness = 100
        precondition(settings.ringThickness == 4.2, "Out-of-range live values must clamp without observer recursion.")
        settings.ringThickness = 2.3
        settings.flushPendingAppearanceChanges()
        precondition(defaults.double(forKey: "ringThickness") == 2.3)
        try await Task.sleep(for: .milliseconds(350))
        precondition(defaults.double(forKey: "ringThickness") == 2.3)

        settings.setLaunchAtLogin(true)
        precondition(settings.launchAtLogin && registerCalls == 1)
        settings.setLaunchAtLogin(true)
        precondition(registerCalls == 1, "Repeated enabling must not register again.")
        settings.setLaunchAtLogin(false)
        let failure = settings.loginError
        precondition(failure?.contains("Test unregister failed") == true && settings.launchAtLogin)
        settings.refreshLoginStatus()
        precondition(settings.loginError == failure, "Passive refresh must retain an operation failure.")
        status = .notRegistered
        settings.refreshLoginStatus()
        precondition(settings.loginError == nil && !settings.launchAtLogin,
                     "A real status change should clear obsolete operation errors.")

        status = .requiresApproval
        settings.refreshLoginStatus()
        precondition(settings.loginError?.contains("登录项") == true)
        settings.setLaunchAtLogin(false)
        precondition(settings.loginError?.contains("Test unregister failed") == true &&
                     settings.loginError?.contains("登录项") == true,
                     "Approval guidance must not hide a failed unregister operation.")
        let approvalFailure = settings.loginError
        settings.refreshLoginStatus()
        precondition(settings.loginError == approvalFailure)
        settings.setLaunchAtLogin(true)
        precondition(settings.loginError?.contains("Test unregister failed") == false,
                     "A user retry should dismiss the previous operation's error.")
        print("AppSettings regressions passed: corrupt preferences, saved choices, live callback, coalesced/exit persistence, login error lifecycle.")
    }
}
