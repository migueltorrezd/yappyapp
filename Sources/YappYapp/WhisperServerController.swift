import Foundation

/// Keeps a local whisper-server process running with the model loaded, so each
/// dictation skips the multi-second model load that whisper-cli pays per run.
/// Main-thread lifecycle state and launch-queue state are separated by
/// `launchLock`; background closures never mutate UI state directly.
final class WhisperServerController: @unchecked Sendable {
    /// The fixed port older builds used. YA-11: each launch now picks a free
    /// random port; this stays the default only for argument-shape callers.
    static let port: UInt16 = 18027
    static let host = "127.0.0.1"

    /// Everything one launch needs, kept so an unexpected exit can relaunch
    /// the same server (YA-11) and a timed-out request can recycle it (YA-05).
    private struct LaunchParameters {
        let binary: String
        let model: String
        let language: String
        let prompt: String
        let translate: Bool
        let quietBoost: Bool
    }

    private var process: Process?
    private var signature: String?
    private var readinessTask: Task<Void, Never>?
    private var lastLaunch: LaunchParameters?
    private var restartBackoff = WhisperServerRestartBackoff()
    private var restartWorkItem: DispatchWorkItem?

    // FIX restartRace: launches run on a background queue (the lsof/port-wait is
    // blocking and must not stall the main thread). This lock-protected counter
    // lets stop()/restart supersede an in-flight launch and gates both the
    // process install and the readiness poller so a superseded launch can never
    // install its process or mark a dying server ready.
    private let launchLock = NSLock()
    private var launchGeneration = 0
    // FIX warmRestart: a launch is "in flight" from beginLaunch() until it either
    // installs its process or gives up. synchronize() consults this so a
    // same-signature call during the launch window early-returns instead of
    // stopping and relaunching a server that is already coming up.
    private var launchInFlight = false
    // FIX quitOrphan: the freshly spawned server is published here (under
    // launchLock) the instant it exists, before it is installed into `process`
    // on the main thread. This lets stop()/deinit/app-termination terminate a
    // server launched during the ~0.3-6.6s window even though the main-thread
    // install may never run (e.g. the app is quitting).
    private var launchedProcess: Process?
    private let launchQueue = DispatchQueue(label: "com.yappyapp.whisper.launch")
    // YA-11: the port and request-path secret of the installed server. Read
    // by transcription requests off the main thread, so it lives under
    // launchLock.
    private var installedEndpoint: WhisperServerEndpoint?

    private(set) var isReady = false

    /// The beam-search setting of the running server, so request timeouts
    /// can scale with it (YA-05).
    var usesBeamSearch: Bool {
        lastLaunch?.quietBoost ?? false
    }

    private var endpoint: WhisperServerEndpoint? {
        launchLock.lock()
        defer { launchLock.unlock() }
        return installedEndpoint
    }

    private func setEndpoint(_ endpoint: WhisperServerEndpoint?) {
        launchLock.lock()
        installedEndpoint = endpoint
        launchLock.unlock()
    }

    /// Starts, restarts, or stops the server so it matches the current config.
    func synchronize(config: AppConfig, glossary: Glossary) {
        guard config.keepModelWarm else {
            stop()
            return
        }

        let modelPath = config.modelPath.expandingTildeInPath

        // HELPER-BINARY-POLICY (YA-63): the server sits next to a validated
        // whisper-cli and must pass the same checks itself.
        guard HelperBinaryPolicy.validate(config.whisperBinaryPath).allowedPath != nil,
              let serverBinary = HelperBinaryPolicy.launchablePath(
                  Self.serverBinaryPath(forWhisperBinaryPath: config.whisperBinaryPath)
              ),
              FileManager.default.fileExists(atPath: modelPath) else {
            stop()
            return
        }

        let language = config.language.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = Self.promptText(config: config, glossary: glossary)
        let translate = config.whisperTranslates
        let quietBoost = config.quietVoiceBoost
        let newSignature = Self.launchSignature(
            binary: serverBinary,
            model: modelPath,
            language: language,
            prompt: prompt,
            translate: translate,
            quietBoost: quietBoost
        )

        // FIX warmRestart: the installed process is set on a later main-thread
        // hop, so during the launch window `process` is still nil. Treat an
        // in-flight launch for the same signature as already-satisfied so
        // back-to-back same-signature synchronize() calls (e.g. two quick config
        // saves) don't stop-and-relaunch a server that is already coming up.
        if newSignature == signature {
            if isLaunchInFlight() { return }
            if let process, process.isRunning { return }
            // YA-11: a crashed server is already waiting out its backoff;
            // saving settings must not turn a crash loop into a hot loop.
            if restartWorkItem != nil { return }
        }

        stop()
        signature = newSignature
        restartBackoff.reset()
        let parameters = LaunchParameters(
            binary: serverBinary,
            model: modelPath,
            language: language,
            prompt: prompt,
            translate: translate,
            quietBoost: quietBoost
        )
        lastLaunch = parameters
        start(parameters)
    }

    /// YA-05: a request that timed out is still running inside the server
    /// and would make the next dictation queue behind it. Replace the server
    /// with a fresh one on the same settings. Main thread.
    func recycle() {
        guard let parameters = lastLaunch, let currentSignature = signature else { return }
        stop()
        signature = currentSignature
        lastLaunch = parameters
        start(parameters)
    }

    func stop() {
        readinessTask?.cancel()
        readinessTask = nil
        restartWorkItem?.cancel()
        restartWorkItem = nil
        isReady = false
        signature = nil
        lastLaunch = nil
        setEndpoint(nil)

        // FIX restartRace: supersede any in-flight background launch so it
        // discards (and terminates) the process it was about to install.
        invalidateLaunch()

        if let process {
            process.terminationHandler = nil
            process.terminate()
        }
        process = nil
    }

    // FIX quitOrphan: guarantee teardown of any in-flight or installed server if
    // the controller is deallocated without an explicit stop().
    deinit {
        stop()
    }

    private func beginLaunch() -> Int {
        launchLock.lock()
        defer { launchLock.unlock() }
        launchGeneration += 1
        launchInFlight = true
        return launchGeneration
    }

    private func invalidateLaunch() {
        launchLock.lock()
        launchGeneration += 1
        launchInFlight = false
        let doomed = launchedProcess
        launchedProcess = nil
        launchLock.unlock()

        // FIX quitOrphan: terminate a launch that has already spawned its server
        // but not yet installed it on the main thread, so stop()/deinit/
        // app-termination during the launch window can never leak an orphan
        // still holding the fixed port.
        if let doomed {
            doomed.terminationHandler = nil
            doomed.terminate()
        }
    }

    private func isCurrentLaunch(_ generation: Int) -> Bool {
        launchLock.lock()
        defer { launchLock.unlock() }
        return launchGeneration == generation
    }

    private func isLaunchInFlight() -> Bool {
        launchLock.lock()
        defer { launchLock.unlock() }
        return launchInFlight
    }

    // FIX quitOrphan: publish the freshly spawned server into lock-guarded shared
    // state the instant it exists (before the liveness sleep) so stop()/deinit
    // can find and terminate it. Returns false if a newer launch already
    // superseded this one, in which case the caller tears the process down.
    private func adoptLaunchedProcess(_ process: Process, generation: Int) -> Bool {
        launchLock.lock()
        defer { launchLock.unlock() }
        guard launchGeneration == generation else { return false }
        launchedProcess = process
        return true
    }

    private func releaseLaunchedProcess(_ process: Process) {
        launchLock.lock()
        if launchedProcess === process { launchedProcess = nil }
        launchLock.unlock()
    }

    private func finishLaunch(_ generation: Int) {
        launchLock.lock()
        if launchGeneration == generation { launchInFlight = false }
        launchLock.unlock()
    }

    /// `timeout` scales with the audio length and beam search (YA-05). A
    /// timeout surfaces as NSURLErrorTimedOut; it is not a reason to hand
    /// the same audio to the cold CLI.
    func transcribe(
        audioURL: URL,
        prompt: String,
        timeout: TimeInterval = TranscriptionTimeouts.serverMinimum
    ) async throws -> String {
        guard let endpoint else { throw WhisperServerControllerError.notRunning }
        let request = try Self.buildInferenceRequest(
            endpoint: endpoint,
            audioURL: audioURL,
            prompt: prompt,
            timeout: timeout
        )

        do {
            return try await performInference(request)
        } catch {
            // A reused socket the server already closed surfaces as a lost
            // connection; retry once on a fresh one before giving up.
            let code = (error as NSError).code
            if code == NSURLErrorNetworkConnectionLost || code == NSURLErrorCannotConnectToHost {
                return try await performInference(request)
            }
            throw error
        }
    }

    static func buildInferenceRequest(
        endpoint: WhisperServerEndpoint,
        audioURL: URL,
        prompt: String,
        timeout: TimeInterval
    ) throws -> URLRequest {
        let boundary = "yappyapp-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint.inferenceURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        // The server drops idle keep-alive sockets after a few seconds; reusing
        // one makes every other dictation fail. Fresh connections cost nothing
        // on localhost.
        request.setValue("close", forHTTPHeaderField: "Connection")
        request.timeoutInterval = max(1, timeout)

        let audioData = try Data(contentsOf: audioURL)
        request.httpBody = Self.inferenceMultipartBody(
            boundary: boundary,
            prompt: prompt,
            audioData: audioData
        )

        return request
    }

    static func inferenceMultipartBody(boundary: String, prompt: String, audioData: Data) -> Data {
        var body = Data()

        func appendField(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }

        appendField("response_format", "json")
        appendField("temperature", "0.0")
        if !prompt.isEmpty {
            // The glossary prompt belongs to this localhost request, not the
            // server process command line where `ps` can expose it.
            appendField("prompt", prompt)
        }

        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(audioData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    private func performInference(_ request: URLRequest) async throws -> String {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw WhisperError.serverFailed("HTTP \(code)")
        }

        return try Self.normalizedInferenceText(from: data)
    }

    static func serverBinaryPath(forWhisperBinaryPath whisperBinaryPath: String) -> String {
        let cliURL = URL(fileURLWithPath: whisperBinaryPath.expandingTildeInPath)
        return cliURL
            .deletingLastPathComponent()
            .appendingPathComponent("whisper-server")
            .path
    }

    static func promptText(config: AppConfig, glossary: Glossary) -> String {
        return [
            glossary.promptPrefix(),
            config.additionalPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }

    static func launchSignature(
        binary: String,
        model: String,
        language: String,
        prompt: String,
        translate: Bool,
        quietBoost: Bool
    ) -> String {
        // Prompt changes no longer require a server restart because each
        // localhost inference request carries its own current prompt.
        _ = prompt
        return [
            binary,
            model,
            language.trimmingCharacters(in: .whitespacesAndNewlines),
            translate ? "tr" : "",
            quietBoost ? "boost" : ""
        ].joined(separator: "|")
    }

    static func launchArguments(
        model: String,
        language: String,
        prompt: String,
        translate: Bool,
        quietBoost: Bool,
        port: UInt16 = WhisperServerController.port,
        requestPath: String? = nil
    ) -> [String] {
        var arguments = [
            "-m", model,
            "--host", host,
            "--port", "\(port)",
            "-nt",
            "-sns"
        ]

        // YA-11: every route lives under a per-launch random secret, so a
        // web page or another local process cannot guess it.
        if let requestPath, !requestPath.isEmpty {
            arguments.append(contentsOf: ["--request-path", requestPath])
        }

        let normalizedLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedLanguage.isEmpty {
            arguments.append(contentsOf: ["-l", normalizedLanguage])
        }

        if translate {
            arguments.append("-tr")
        }

        if quietBoost {
            // Keep low-energy (whispered) segments and decode with beam search.
            arguments.append(contentsOf: ["-nth", "0.95", "-bs", "5"])
        }

        // `prompt` intentionally does not enter argv. The caller sends it in
        // the private localhost multipart request for each transcription.
        _ = prompt

        return arguments
    }

    static func normalizedInferenceText(from data: Data) throws -> String {
        struct InferenceResponse: Decodable {
            let text: String
        }

        let decoded = try JSONDecoder().decode(InferenceResponse.self, from: data)
        let normalized = decoded.text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty else {
            throw WhisperError.emptyTranscript
        }

        return normalized
    }

    private func start(_ parameters: LaunchParameters) {
        let generation = beginLaunch()
        let binary = parameters.binary

        // FIX restartRace: the whole launch (blocking ps/lsof, process spawn,
        // bind-race retry) runs off the calling (main) thread.
        launchQueue.async { [weak self] in
            guard let self else { return }

            Self.killStrandedServers(matchingBinaryPath: binary)

            var launched: (process: Process, endpoint: WhisperServerEndpoint)?
            for _ in 0..<3 {
                guard self.isCurrentLaunch(generation) else { return }

                // YA-11: a fresh free port and request-path secret per launch.
                guard let port = LocalPortAllocator.freePort() else { continue }
                let endpoint = WhisperServerEndpoint.random(port: port)
                let arguments = Self.launchArguments(
                    model: parameters.model,
                    language: parameters.language,
                    prompt: parameters.prompt,
                    translate: parameters.translate,
                    quietBoost: parameters.quietBoost,
                    port: endpoint.port,
                    requestPath: endpoint.requestPath
                )

                guard let process = Self.launchServer(binary: binary, arguments: arguments) else {
                    self.finishLaunch(generation)
                    return
                }

                // FIX quitOrphan: record the live handle in shared state before
                // the liveness sleep, so a stop()/app-quit during that window can
                // still terminate it. If a newer launch already won, tear this
                // one down now instead of leaking it.
                guard self.adoptLaunchedProcess(process, generation: generation) else {
                    process.terminationHandler = nil
                    process.terminate()
                    return
                }

                // A server that cannot start exits within a beat; keep only
                // one that is still alive, otherwise retry on a new port.
                Thread.sleep(forTimeInterval: 0.3)
                if process.isRunning {
                    launched = (process, endpoint)
                    break
                }
                self.releaseLaunchedProcess(process)
                process.terminationHandler = nil
            }

            guard let launched else {
                self.finishLaunch(generation)
                return
            }
            let process = launched.process

            DispatchQueue.main.async { [self] in
                guard self.isCurrentLaunch(generation) else {
                    // A newer stop()/start() superseded this launch; tear the
                    // orphan down rather than leaking it.
                    process.terminationHandler = nil
                    process.terminate()
                    self.releaseLaunchedProcess(process)
                    return
                }

                process.terminationHandler = { [weak self] exited in
                    guard let controller = self else { return }
                    DispatchQueue.main.async { [controller] in
                        controller.handleUnexpectedTermination(of: exited)
                    }
                }
                self.process = process
                self.setEndpoint(launched.endpoint)
                // FIX quitOrphan: `process` is now the authority for teardown;
                // drop the launch-window handle so stop() terminates it exactly
                // once and a later superseded release can't touch it.
                self.releaseLaunchedProcess(process)
                self.finishLaunch(generation)
                self.pollReadiness(generation: generation, endpoint: launched.endpoint, childPID: process.processIdentifier)
            }
        }
    }

    /// YA-11: stop() and recycle() clear the termination handler before they
    /// terminate, so reaching this means the server died on its own (a crash,
    /// a kill, an out-of-memory exit). Relaunch it with exponential backoff
    /// so dictation does not silently fall back to the slow cold CLI.
    private func handleUnexpectedTermination(of exited: Process) {
        guard process === exited else { return }
        process = nil
        isReady = false
        setEndpoint(nil)
        readinessTask?.cancel()
        readinessTask = nil

        guard let parameters = lastLaunch, let currentSignature = signature else { return }
        let delay = restartBackoff.nextDelay(now: Date())
        restartWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.restartWorkItem = nil
            // Settings may have changed or the server been stopped meanwhile.
            guard self.signature == currentSignature, self.process == nil, !self.isLaunchInFlight() else { return }
            self.start(parameters)
        }
        restartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private static func launchServer(binary: String, arguments: [String]) -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments

        // whisper-server output can echo private vocabulary. Keep it off disk
        // by default. Developers can opt in explicitly; the resulting file is
        // truncated and owner-only rather than world-readable and cumulative.
        let logHandle = diagnosticLogHandleIfEnabled()
        process.standardOutput = logHandle ?? FileHandle.nullDevice
        process.standardError = logHandle ?? FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        return process
    }

    private static func diagnosticLogHandleIfEnabled() -> FileHandle? {
        guard ProcessInfo.processInfo.environment["YAPPYAPP_WHISPER_SERVER_LOG"] == "1" else {
            return nil
        }

        do {
            try PrivateFile.write(Data(), to: AppPaths.serverLogURL)
            let handle = try FileHandle(forWritingTo: AppPaths.serverLogURL)
            try handle.truncate(atOffset: 0)
            return handle
        } catch {
            return nil
        }
    }

    private func pollReadiness(generation: Int, endpoint: WhisperServerEndpoint, childPID: pid_t) {
        readinessTask?.cancel()
        isReady = false

        readinessTask = Task { [weak self] in
            // Large models take a while to load; the server only binds its
            // port once the model is in memory.
            for _ in 0..<240 {
                guard !Task.isCancelled else { return }
                guard let self else { return }

                // YA-11: the health route sits behind the request-path secret,
                // and the listener on the port must be our own child process.
                if await Self.ping(endpoint),
                   WhisperServerListenerCheck.ownsListener(
                       listenerPIDs: Self.listeningPIDs(port: endpoint.port),
                       childPID: childPID
                   ) {
                    // FIX readyRace: between the ping succeeding and this
                    // assignment the poller can be cancelled (stop()/restart) or
                    // its launch superseded; either way the ping may have hit a
                    // dying server. Re-check both here and again after the main
                    // hop before claiming ready.
                    guard !Task.isCancelled, self.isCurrentLaunch(generation) else { return }
                    await MainActor.run {
                        guard !Task.isCancelled, self.isCurrentLaunch(generation) else { return }
                        self.isReady = true
                        self.restartBackoff.markReady(at: Date())
                    }
                    return
                }

                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private static func ping(_ endpoint: WhisperServerEndpoint) async -> Bool {
        var request = URLRequest(url: endpoint.healthURL)
        request.timeoutInterval = 1.5

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    /// YA-11: a crashed earlier app instance can leave its server running,
    /// re-parented to launchd. Only processes started from *our* exact
    /// whisper-server binary are touched, never an unrelated listener or
    /// another live instance's child. Runs off-main.
    private static func killStrandedServers(matchingBinaryPath binary: String) {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        // macOS `ps -o comm=` prints the full executable path, which matches
        // how we launch the server (full-path executableURL).
        ps.arguments = ["-axo", "pid=,ppid=,comm="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice

        do {
            try ps.run()
        } catch {
            return
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        for pid in StrandedWhisperServers.pids(psOutput: output, binaryPath: binary) {
            kill(pid, SIGTERM)
        }
    }

    /// Shared with the warm cleanup server's readiness check.
    static func listeningPIDs(port: UInt16) -> [pid_t] {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-ti", "tcp:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.standardError = FileHandle.nullDevice

        do {
            try lsof.run()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        lsof.waitUntilExit()

        return (String(data: data, encoding: .utf8) ?? "")
            .split(whereSeparator: { $0 == "\n" || $0 == " " })
            .compactMap { pid_t($0) }
    }
}

/// YA-11: where one warm whisper-server launch listens. Every launch gets a
/// fresh localhost port and a random request-path secret, so nothing outside
/// this app instance can guess the routes, and a stale or squatting listener
/// on an old port is never mistaken for our server.
struct WhisperServerEndpoint: Equatable, Sendable {
    static let requestPathPrefix = "/yappyapp-"

    let port: UInt16
    let requestPath: String

    static func random(port: UInt16) -> WhisperServerEndpoint {
        WhisperServerEndpoint(port: port, requestPath: requestPathPrefix + randomSecret())
    }

    /// 128 random bits as lowercase hex. URL-safe and never logged.
    static func randomSecret() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<4)
            .map { _ in String(format: "%08x", UInt32.random(in: .min ... .max, using: &generator)) }
            .joined()
    }

    var baseURL: URL {
        // Pinned to loopback: the literal keeps the network policy check honest.
        URL(string: "http://127.0.0.1:\(port)\(requestPath)")!
    }

    var inferenceURL: URL {
        baseURL.appendingPathComponent("inference")
    }

    var healthURL: URL {
        baseURL.appendingPathComponent("health")
    }
}
