import Foundation

// LLAMA-SERVER-WARM: a persistent llama-server keeps a GGUF model loaded, so
// a dictation skips the per-run process spawn and model load that the
// one-shot llama-completion pays every time. One controller type runs three
// instances: `.cleanup` (the Qwen cleanup model, see CleanupServer.swift),
// `.translation` (the chosen Hy-MT2 model, see TranslationServer.swift) and
// `.speech` (a Qwen3-ASR model with its audio projector, see
// Qwen3ASRServer.swift).
//
// Both mirror the warm whisper-server: 127.0.0.1 only, a fresh free port and
// a random path prefix per launch, readiness only from our own child,
// restart with backoff after a crash, and stop on quit or when their policy
// returns no launch (feature off, "keep the model warm" off, critical memory
// pressure, no verified model). A different launch (another model) replaces
// the running server.
//
// One tiny warm-up request runs right after the server answers /health, so
// the Metal kernels compile before the user's first dictation, not during it.
//
// PRIVACY: the transcript, glossary terms and recorded audio travel only in
// the body of a loopback request, never in argv. The server's stdout and stderr go to
// /dev/null with logging off, so nothing it prints reaches a file.
//
// FALLBACK: when the server is not ready, serves another model, or a request
// cannot be delivered, the caller runs the one-shot llama-completion exactly
// as before. A llama-cli the user chose never starts a server.

/// What one warm server runs: the helper, the verified model and its context.
struct LlamaServerLaunch: Equatable, Sendable {
    let binary: String
    let model: String
    let contextTokens: Int
    /// QWEN3-ASR: the audio projector (--mmproj) of a multimodal model.
    var projector: String? = nil
}

/// One OpenAI-style chat request. Transcript text lives only in `messages`.
struct LlamaChatRequest: Equatable, Sendable {
    struct Message: Equatable, Sendable {
        var role: String
        var content: String
    }

    var messages: [Message]
    var maxTokens: Int
    var timeout: TimeInterval
    /// nil keeps the server default, like a one-shot run without the flag.
    var repeatPenalty: Double?
}

enum LlamaServerReply: Equatable, Sendable {
    case text(String)
    /// The server took the request and did not answer in time.
    case timedOut
    /// Not running, still loading, serving another model, or the request
    /// never reached it: run the one-shot helper instead.
    case unavailable
}

/// What the support report says about a warm server.
enum LlamaServerStatus: String, Equatable, Sendable {
    case notRunning = "not running"
    case starting
    case ready
    case waitingToRestart = "waiting to restart"
}

/// Pure rules shared by both servers, pinned by the self-tests.
enum LlamaServerPolicy {
    static let serverBinaryName = "llama-server"

    /// llama-server sits next to the llama-completion it was built with.
    static func serverBinaryPath(forRuntimeBinary runtimeBinary: String) -> String {
        URL(fileURLWithPath: runtimeBinary)
            .deletingLastPathComponent()
            .appendingPathComponent(serverBinaryName)
            .path
    }

    /// The bundled server next to `runtimeBinary`, or nil. Only the bundled
    /// style `llama-completion` gets a server, never a user's llama-cli.
    static func bundledServer(runtimeBinary: String?, launchable: (String) -> String?) -> String? {
        guard let runtimeBinary, LLMCleaner.Runtime.of(binaryPath: runtimeBinary) == .completion else {
            return nil
        }
        return launchable(serverBinaryPath(forRuntimeBinary: runtimeBinary))
    }

    /// Same model settings as the one-shot run: all layers on the GPU, the
    /// same context, one slot. No web UI, no logs, loopback only.
    static func launchArguments(model: String, contextTokens: Int, port: UInt16, apiPrefix: String, projector: String? = nil) -> [String] {
        var arguments = [
            "-m", model,
            "--host", WhisperServerController.host,
            "--port", "\(port)",
            "--api-prefix", apiPrefix,
            "-ngl", "99",
            "-c", String(contextTokens),
            "-np", "1",
            "--no-webui",
            "--log-disable",
            // The model's own chat template, like the one-shot runs.
            "--jinja"
        ]
        if let projector {
            arguments.append(contentsOf: ["--mmproj", projector])
        }
        return arguments
    }

    /// Greedy like `--temp 0`, with the prompt cached between dictations.
    static func requestBody(_ request: LlamaChatRequest) -> Data {
        var body: [String: Any] = [
            "messages": request.messages.map { ["role": $0.role, "content": $0.content] },
            "temperature": 0,
            "max_tokens": request.maxTokens,
            "cache_prompt": true,
            "stream": false
        ]
        if let repeatPenalty = request.repeatPenalty {
            body["repeat_penalty"] = repeatPenalty
        }
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    static func replyText(from data: Data) -> String? {
        struct Reply: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message
            }
            let choices: [Choice]
        }
        return (try? JSONDecoder().decode(Reply.self, from: data))?.choices.first?.message.content
    }

    static func chatURL(_ endpoint: WhisperServerEndpoint) -> URL {
        endpoint.baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("chat")
            .appendingPathComponent("completions")
    }

    static func status(ready: Bool, process: Bool, launching: Bool, restartPending: Bool) -> LlamaServerStatus {
        if ready { return .ready }
        if restartPending { return .waitingToRestart }
        if launching || process { return .starting }
        return .notRunning
    }
}

/// Owns one warm llama-server. Thread-safe: every piece of state sits under
/// `lock`, launches run on a private queue, and requests block the calling
/// (background) thread, like the one-shot runner they replace.
final class LlamaServerController: @unchecked Sendable {
    /// Loading a multi-gigabyte model from a cold disk can take a while; past
    /// this the launch is abandoned and the one-shot helper keeps working.
    static let readinessTimeout: TimeInterval = 90

    private let lock = NSLock()
    private let queue: DispatchQueue
    /// One token through the pipeline right after /health answers.
    private let warmUpBody: Data
    private let warmUpTimeout: TimeInterval
    private var desired: LlamaServerLaunch?
    private var process: Process?
    private var readyEndpoint: WhisperServerEndpoint?
    private var readyModel: String?
    private var generation = 0
    private var restartBackoff = WhisperServerRestartBackoff()
    private var restartPending = false
    private var launching = false

    convenience init(label: String, warmUp: LlamaChatRequest) {
        self.init(label: label, warmUpBody: LlamaServerPolicy.requestBody(warmUp), warmUpTimeout: warmUp.timeout)
    }

    /// QWEN3-ASR: a warm-up that is not a text chat (a short silent clip).
    init(label: String, warmUpBody: Data, warmUpTimeout: TimeInterval) {
        queue = DispatchQueue(label: "com.yappyapp.\(label)-server")
        self.warmUpBody = warmUpBody
        self.warmUpTimeout = warmUpTimeout
    }

    var isReady: Bool {
        lock.lock(); defer { lock.unlock() }
        return readyEndpoint != nil
    }

    var status: LlamaServerStatus {
        lock.lock(); defer { lock.unlock() }
        return LlamaServerPolicy.status(
            ready: readyEndpoint != nil,
            process: process != nil,
            launching: launching,
            restartPending: restartPending
        )
    }

    /// Starts, restarts or stops the server to match `launch`.
    func synchronize(_ launch: LlamaServerLaunch?) {
        lock.lock()
        // Same server already running, coming up, or waiting out a crash
        // backoff: nothing to do, so polling never turns into a relaunch.
        if launch == desired, launch == nil || process != nil || restartPending || launching {
            lock.unlock()
            return
        }
        let doomed = tearDownLocked()
        desired = launch
        restartBackoff.reset()
        launching = launch != nil
        let generation = generation
        lock.unlock()
        terminate(doomed)
        if let launch {
            queue.async { self.start(launch, generation: generation) }
        }
    }

    func stop() {
        synchronize(nil)
    }

    /// A request that timed out is still running inside the single slot and
    /// would make the next dictation queue behind it: replace the server.
    func recycle() {
        lock.lock()
        guard let launch = desired else { lock.unlock(); return }
        let doomed = tearDownLocked()
        launching = true
        let generation = generation
        lock.unlock()
        terminate(doomed)
        queue.async { self.start(launch, generation: generation) }
    }

    deinit {
        lock.lock()
        let doomed = tearDownLocked()
        lock.unlock()
        terminate(doomed)
    }

    /// Blocking. Call off the main thread. With `model`, a server that has
    /// another model loaded (a switch still in flight) is `.unavailable`.
    func complete(_ request: LlamaChatRequest, model: String? = nil) -> LlamaServerReply {
        complete(body: LlamaServerPolicy.requestBody(request), timeout: request.timeout, model: model)
    }

    /// Blocking, like `complete(_:model:)`, for a chat body built elsewhere
    /// (QWEN3-ASR sends the recording as an input_audio part).
    func complete(body: Data, timeout: TimeInterval, model: String? = nil) -> LlamaServerReply {
        lock.lock()
        let endpoint = readyEndpoint
        let loaded = readyModel
        lock.unlock()
        guard let endpoint else { return .unavailable }
        if let model, model != loaded { return .unavailable }

        var urlRequest = URLRequest(url: LlamaServerPolicy.chatURL(endpoint))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("close", forHTTPHeaderField: "Connection")
        urlRequest.timeoutInterval = max(1, timeout)
        urlRequest.httpBody = body

        switch Self.send(urlRequest, timeout: timeout) {
        case .success(let data):
            guard let text = LlamaServerPolicy.replyText(from: data) else { return .unavailable }
            return .text(text)
        case .failure(let failure):
            if failure == .timedOut {
                recycle()
                return .timedOut
            }
            return .unavailable
        }
    }

    /// Blocking: waits until the server answers or `timeout` passes. For the
    /// latency harnesses only.
    @discardableResult
    func waitUntilReady(timeout: TimeInterval = readinessTimeout) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !isReady, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        return isReady
    }

    // MARK: - Launch

    /// Clears the running state and supersedes any launch in flight.
    /// Returns the process to terminate outside the lock.
    private func tearDownLocked() -> Process? {
        generation += 1
        readyEndpoint = nil
        readyModel = nil
        restartPending = false
        launching = false
        let doomed = process
        process = nil
        return doomed
    }

    private func terminate(_ process: Process?) {
        guard let process else { return }
        process.terminationHandler = nil
        if process.isRunning { process.terminate() }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return self.generation == generation
    }

    private func start(_ launch: LlamaServerLaunch, generation: Int) {
        guard isCurrent(generation) else { return }
        Self.killStrandedServers(matchingBinaryPath: launch.binary)
        if attemptLaunch(launch, generation: generation) {
            lock.lock()
            if self.generation == generation { launching = false }
            lock.unlock()
        } else {
            scheduleRetry(launch, generation: generation)
        }
    }

    /// Up to three ports. True once a server of ours answers and is warm, or
    /// when a newer synchronize superseded this launch.
    private func attemptLaunch(_ launch: LlamaServerLaunch, generation: Int) -> Bool {
        for _ in 0..<3 {
            guard isCurrent(generation) else { return true }
            guard let port = LocalPortAllocator.freePort() else { continue }
            let endpoint = WhisperServerEndpoint.random(port: port)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launch.binary)
            process.arguments = LlamaServerPolicy.launchArguments(
                model: launch.model,
                contextTokens: launch.contextTokens,
                port: port,
                apiPrefix: endpoint.requestPath,
                projector: launch.projector
            )
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { [weak self] exited in
                self?.handleExit(of: exited, generation: generation)
            }
            do {
                try process.run()
            } catch {
                return false
            }

            lock.lock()
            guard self.generation == generation else {
                lock.unlock()
                terminate(process)
                return true
            }
            self.process = process
            lock.unlock()

            if waitUntilReady(endpoint, process: process, generation: generation) {
                warmUp(endpoint)
                lock.lock()
                if self.generation == generation, self.process === process {
                    readyEndpoint = endpoint
                    readyModel = launch.model
                    restartBackoff.markReady(at: Date())
                }
                lock.unlock()
                return true
            }
            // Not ours on that port, or it died: try again on a new port.
            lock.lock()
            let stillCurrent = self.generation == generation
            if stillCurrent, self.process === process { self.process = nil }
            lock.unlock()
            terminate(process)
            guard stillCurrent else { return true }
        }
        return false
    }

    /// A launch that never came up waits out the same backoff as a crash,
    /// so a broken helper is retried slowly instead of on every poll.
    private func scheduleRetry(_ launch: LlamaServerLaunch, generation: Int) {
        lock.lock()
        guard self.generation == generation else { lock.unlock(); return }
        launching = false
        restartPending = true
        let delay = restartBackoff.nextDelay(now: Date())
        lock.unlock()
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.retry(launch, generation: generation)
        }
    }

    private func retry(_ launch: LlamaServerLaunch, generation: Int) {
        lock.lock()
        guard self.generation == generation, desired == launch, restartPending else {
            lock.unlock()
            return
        }
        restartPending = false
        launching = true
        lock.unlock()
        start(launch, generation: generation)
    }

    private func waitUntilReady(_ endpoint: WhisperServerEndpoint, process: Process, generation: Int) -> Bool {
        let deadline = Date().addingTimeInterval(Self.readinessTimeout)
        while Date() < deadline {
            guard isCurrent(generation), process.isRunning else { return false }
            if Self.health(endpoint) {
                return WhisperServerListenerCheck.ownsListener(
                    listenerPIDs: WhisperServerController.listeningPIDs(port: endpoint.port),
                    childPID: process.processIdentifier
                )
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    /// One token through the whole pipeline compiles the Metal kernels and
    /// caches the prompt prefix before the first real dictation.
    private func warmUp(_ endpoint: WhisperServerEndpoint) {
        var request = URLRequest(url: LlamaServerPolicy.chatURL(endpoint))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("close", forHTTPHeaderField: "Connection")
        request.timeoutInterval = warmUpTimeout
        request.httpBody = warmUpBody
        _ = Self.send(request, timeout: warmUpTimeout)
    }

    /// The server died on its own (stop and recycle clear the handler first):
    /// relaunch with exponential backoff, like the warm whisper-server.
    private func handleExit(of exited: Process, generation: Int) {
        lock.lock()
        // While launching, the launch loop sees the exit itself and retries.
        guard self.generation == generation, process === exited, !launching, let launch = desired else {
            lock.unlock()
            return
        }
        process = nil
        readyEndpoint = nil
        readyModel = nil
        restartPending = true
        let delay = restartBackoff.nextDelay(now: Date())
        lock.unlock()

        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.retry(launch, generation: generation)
        }
    }

    // MARK: - HTTP

    private enum SendFailure: Error, Equatable {
        case timedOut
        case failed
    }

    private final class ResultBox: @unchecked Sendable {
        var value: Result<Data, SendFailure> = .failure(.failed)
    }

    private static func send(_ request: URLRequest, timeout: TimeInterval) -> Result<Data, SendFailure> {
        let box = ResultBox()
        let done = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error as? URLError, error.code == .timedOut {
                box.value = .failure(.timedOut)
            } else if let data, (response as? HTTPURLResponse)?.statusCode == 200 {
                box.value = .success(data)
            }
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + max(1, timeout) + 1) == .timedOut {
            task.cancel()
            return .failure(.timedOut)
        }
        return box.value
    }

    private static func health(_ endpoint: WhisperServerEndpoint) -> Bool {
        var request = URLRequest(url: endpoint.healthURL)
        request.timeoutInterval = 1
        if case .success = send(request, timeout: 1) { return true }
        return false
    }

    /// A server left behind by a crashed app (parent gone) that ran the same
    /// helper. Both instances share the binary, so only a stranded server is
    /// killed: a live sibling still has this app as its parent.
    private static func killStrandedServers(matchingBinaryPath binary: String) {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-axo", "pid=,ppid=,comm="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        do { try ps.run() } catch { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        for pid in StrandedWhisperServers.pids(psOutput: String(decoding: data, as: UTF8.self), binaryPath: binary) {
            kill(pid, SIGTERM)
        }
    }
}
