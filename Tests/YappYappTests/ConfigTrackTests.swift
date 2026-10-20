import Foundation
import Testing
@testable import YappYapp

// Pure logic owned by the "config" track: config repair, managed
// preferences, login-item approval and the helper binary policy.

@Test
func damagedConfigFailsClosedOnDownloads() {
    let outcome = ConfigRecovery.decode(
        data: Data(#"{"language": "fr", "allowMod"#.utf8),
        installDefaults: AppConfig.defaultConfig,
        lastSaved: { nil }
    )
    #expect(outcome.isDamaged)
    #expect(outcome.config.allowModelDownloads == false)
    #expect(outcome.config.language == "fr")
}

@Test
func managedOverridesNeverPersistOverUserValue() {
    let overrides = ManagedOverrides.read(from: StaticManagedPreferences([.allowModelDownloads: .bool(false)]))
    var user = AppConfig.defaultConfig
    user.allowModelDownloads = true
    let effective = overrides.apply(to: user)
    #expect(effective.allowModelDownloads == false)
    #expect(overrides.restoringUserValues(in: effective, from: user).allowModelDownloads == true)
}

@Test
func loginItemApprovalIsNotReportedAsEnabled() {
    let outcome = LaunchAtLoginPresenter.outcome(requestedEnabled: true, status: .requiresApproval, errorDescription: nil)
    #expect(outcome.needsApproval)
    #expect(!outcome.isEnabled)
}

@Test
func helperPolicyRefusesRelativeAndWritablePaths() {
    let facts = HelperFileFacts(exists: true, isRegularFile: true, isExecutable: true, posixPermissions: 0o777, ownerID: 501)
    #expect(HelperBinaryPolicy.validate("whisper-cli", bundleURL: nil, currentUserID: 501, facts: { _ in facts }) == .refused(.relativePath))
    #expect(HelperBinaryPolicy.validate("/x/whisper-cli", bundleURL: nil, currentUserID: 501, facts: { _ in facts }) == .refused(.writableByOthers))
}
