import Foundation
import Testing
@testable import YappYapp

@Test
func parakeetReadinessRequiresInstalledModel() {
    var config = AppConfig.defaultConfig
    config.modelPath = "parakeet://v3"
    config.allowModelDownloads = true
    let snapshot = ModelReadinessPresenter.snapshot(
        config: config,
        whisperReadiness: (binary: false, model: false),
        selectedModelInstalled: false
    )
    #expect(snapshot.isModelReady == false)
}

@Test
func englishOnlyActivationKeepsSavedLanguage() throws {
    var config = AppConfig.defaultConfig
    config.language = "nl"
    let option = try #require(ModelCatalog.option(for: "parakeet-v2"))
    let plan = ModelActivationPlanner.plan(currentConfig: config, option: option)
    #expect(plan.config.language == "nl")
    #expect(TranscriptionLanguage.effectiveLanguage(for: plan.config) == "en")
}

@Test
func stickyErrorsOnlyClearOnSameTopic() {
    let error = TabFeedback.error("Could not change the login item.", topic: "login-item")
    #expect(TabFeedbackPolicy.merge(existing: error, incoming: .success("Setup saved.", topic: "save")) == error)
    let fixed = TabFeedback.success("YappYapp will start automatically at login.", topic: "login-item")
    #expect(TabFeedbackPolicy.merge(existing: error, incoming: fixed) == fixed)
}

@Test
func loginLaunchWithFinishedSetupStaysInMenuBar() {
    #expect(ControlWindowLaunchPolicy.opensOnLaunch(setupComplete: true, launchedAsLoginItem: true) == false)
    #expect(ControlWindowLaunchPolicy.opensOnLaunch(setupComplete: false, launchedAsLoginItem: true))
    #expect(ControlWindowLaunchPolicy.opensOnLaunch(setupComplete: true, launchedAsLoginItem: false))
}

@Test
func hudLabelsUseWords() {
    #expect(HUDLabelPresenter.trailingLabel(phase: .pasted, recordingSeconds: 0) == "PASTED")
    #expect(HUDLabelPresenter.trailingLabel(phase: .idle, recordingSeconds: 0) == "READY")
    #expect(HUDLabelPresenter.trailingLabel(phase: .error("x"), recordingSeconds: 0) == "DIDN'T WORK")
}

@Test
func downloadErrorsAvoidRawStrings() {
    #expect(DownloadErrorCopy.plain(URLError(.notConnectedToInternet)) == DownloadErrorCopy.offline)
    #expect(DownloadErrorCopy.plain(URLError(.badServerResponse)) == DownloadErrorCopy.generic)
}
