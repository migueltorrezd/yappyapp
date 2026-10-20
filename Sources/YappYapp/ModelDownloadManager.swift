import Foundation

/// Delegate-driven Whisper downloader. Parakeet manifest resolution and cache
/// installation live in `ParakeetModelDistribution`; this class owns only the
/// resumable URLSession task lifecycle and its MainActor event boundary.
final class ModelDownloadManager: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    typealias ProgressHandler = @MainActor @Sendable (String, Double) -> Void
    typealias CompletionHandler = @MainActor @Sendable (String, Error?) -> Void

    static let whisperModelRevision = "5359861c739e955e79d9a303bcbc70fb988958b1"

    private struct Callbacks {
        var onProgress: ProgressHandler?
        var onCompletion: CompletionHandler?
    }

    /// Handlers are always invoked on MainActor. Their storage shares the same
    /// lock as task state so assignment cannot race a delegate callback.
    var onProgress: ProgressHandler? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return callbacks.onProgress
        }
        set {
            lock.lock()
            callbacks.onProgress = newValue
            lock.unlock()
        }
    }

    var onCompletion: CompletionHandler? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return callbacks.onCompletion
        }
        set {
            lock.lock()
            callbacks.onCompletion = newValue
            lock.unlock()
        }
    }

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.allowsConstrainedNetworkAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.httpAdditionalHeaders = ["User-Agent": "YappYapp/0.2"]
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.networkServiceType = .responsiveData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 14_400
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    // URLSession's delegate entry points are Sendable and may arrive on an
    // arbitrary queue. Every mutable field below is protected by this lock;
    // `@unchecked Sendable` documents that synchronization boundary.
    private let lock = NSLock()
    private var callbacks = Callbacks()
    private var coordinator = WhisperDownloadCoordinator()
    private var taskByModelID: [String: URLSessionDownloadTask] = [:]

    static func downloadURL(for option: ModelOption) -> URL? {
        guard option.engine == .whisper, !option.filename.isEmpty else { return nil }
        return URL(
            string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(whisperModelRevision)/\(option.filename)"
        )
    }

    static func normalizedProgress(
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) -> Double? {
        guard totalBytesExpectedToWrite > 0 else { return nil }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        return min(max(fraction, 0), 1)
    }

    static func httpStatusErrorMessage(_ statusCode: Int?) -> String? {
        guard let statusCode, ![200, 206].contains(statusCode) else { return nil }
        return "Download returned HTTP \(statusCode)"
    }

    static func shouldNotifyCompletion(for error: Error?) -> Bool {
        guard let error else { return false }
        return (error as NSError).code != NSURLErrorCancelled
    }

    // MARK: - Parakeet compatibility facade

    static func parakeetDownloadPlan(for variant: String) -> ParakeetDownloadPlan {
        ParakeetModelDistribution.plan(for: variant)
    }

    static func isVerifiedParakeetCache(variant: String) -> Bool {
        ParakeetModelDistribution.isVerifiedCache(variant: variant)
    }

    static func downloadParakeet(
        variant: String,
        progress: @escaping @Sendable (ParakeetDownloadProgress) -> Void
    ) async throws {
        try await ParakeetModelDistribution.download(variant: variant, progress: progress)
    }

    static func isSafeRelativeModelPath(_ path: String) -> Bool {
        ParakeetManifestResolver.isSafeRelativeModelPath(path)
    }

    static func isValidHexDigest(_ digest: String, length: Int) -> Bool {
        ParakeetManifestResolver.isValidHexDigest(digest, length: length)
    }

    static func nextPageURL(from response: HTTPURLResponse) -> URL? {
        ParakeetManifestResolver.nextPageURL(from: response)
    }

    // MARK: - Whisper task lifecycle

    func download(option: ModelOption) {
        guard let url = Self.downloadURL(for: option) else { return }

        lock.lock()
        // Taking the task here gives this restart sole ownership. A concurrent
        // cancel(id:) sees no task and cannot cancel the same transfer twice.
        let existingTask = taskByModelID.removeValue(forKey: option.id)
        let preparation = coordinator.prepareDownload(
            option: option,
            url: url,
            replacingActiveTask: existingTask != nil
        )
        lock.unlock()

        switch preparation {
        case .start(let pending):
            startDownload(pending)
        case .reclaim(let pending):
            existingTask?.cancel(byProducingResumeData: { [weak self, pending] resumeData in
                self?.startDownload(
                    WhisperPendingStart(
                        intent: pending.intent,
                        fallbackResumeData: resumeData ?? pending.fallbackResumeData
                    )
                )
            })
        case .waitForCancellation:
            break
        }
    }

    func cancel(id: String) {
        lock.lock()
        let task = taskByModelID.removeValue(forKey: id)
        if let taskID = coordinator.taskID(for: id) {
            coordinator.cleanupTask(taskID: taskID, modelID: id)
        }
        let generation = coordinator.prepareCancellation(
            modelID: id,
            hasActiveTask: task != nil
        )
        lock.unlock()

        guard let task else { return }
        task.cancel(byProducingResumeData: { [weak self] resumeData in
            guard let self else { return }

            self.lock.lock()
            let pending = self.coordinator.completeCancellation(
                modelID: id,
                cancelGeneration: generation,
                resumeData: resumeData
            )
            self.lock.unlock()

            if let pending {
                self.startDownload(pending)
            }
        })
    }

    private func startDownload(_ pending: WhisperPendingStart) {
        lock.lock()
        guard coordinator.accepts(pending.intent) else {
            lock.unlock()
            return
        }

        let task: URLSessionDownloadTask = if let resumeData = pending.fallbackResumeData {
            session.downloadTask(withResumeData: resumeData)
        } else {
            session.downloadTask(with: pending.intent.url)
        }

        coordinator.trackTask(
            taskID: task.taskIdentifier,
            intent: pending.intent,
            destination: URL(fileURLWithPath: pending.intent.option.expandedPath)
        )
        taskByModelID[pending.intent.option.id] = task
        // Resume before releasing task ownership. A concurrent cancel can now
        // always see and cancel a running task, never a suspended orphan.
        task.resume()
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let progress = Self.normalizedProgress(
            totalBytesWritten: totalBytesWritten,
            totalBytesExpectedToWrite: totalBytesExpectedToWrite
        ) else { return }

        lock.lock()
        let record = coordinator.record(for: downloadTask.taskIdentifier)
        let handler = callbacks.onProgress
        lock.unlock()

        guard let record, let handler else { return }
        Task { @MainActor in
            handler(record.option.id, progress)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        let record = coordinator.record(for: downloadTask.taskIdentifier)
        lock.unlock()
        guard let record else { return }

        let httpStatusCode = (downloadTask.response as? HTTPURLResponse)?.statusCode
        if let errorMessage = Self.httpStatusErrorMessage(httpStatusCode) {
            cleanup(taskID: downloadTask.taskIdentifier, modelID: record.option.id)
            notifyCompletion(
                modelID: record.option.id,
                error: WhisperError.serverFailed(errorMessage)
            )
            return
        }

        do {
            try ModelIntegrity.verifyDownloadedFile(at: location, option: record.option)
            try FileManager.default.createDirectory(
                at: record.destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: record.destination.path) {
                try FileManager.default.removeItem(at: record.destination)
            }
            try FileManager.default.moveItem(at: location, to: record.destination)
        } catch {
            cleanup(taskID: downloadTask.taskIdentifier, modelID: record.option.id)
            notifyCompletion(modelID: record.option.id, error: error)
            return
        }

        lock.lock()
        coordinator.clearResumeData(for: record.option.id)
        lock.unlock()

        cleanup(taskID: downloadTask.taskIdentifier, modelID: record.option.id)
        notifyCompletion(modelID: record.option.id, error: nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }

        lock.lock()
        let record = coordinator.record(for: task.taskIdentifier)
        if let record,
           let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data,
           let generation = coordinator.taskGeneration(for: task.taskIdentifier) {
            coordinator.storeResumeData(
                resumeData,
                modelID: record.option.id,
                generation: generation
            )
        }
        lock.unlock()

        guard let record else { return }
        cleanup(taskID: task.taskIdentifier, modelID: record.option.id)
        if Self.shouldNotifyCompletion(for: error) {
            notifyCompletion(modelID: record.option.id, error: error)
        }
    }

    private func cleanup(taskID: Int, modelID: String) {
        lock.lock()
        coordinator.cleanupTask(taskID: taskID, modelID: modelID)
        if taskByModelID[modelID]?.taskIdentifier == taskID {
            taskByModelID.removeValue(forKey: modelID)
        }
        lock.unlock()
    }

    private func notifyCompletion(modelID: String, error: Error?) {
        lock.lock()
        let handler = callbacks.onCompletion
        lock.unlock()

        guard let handler else { return }
        Task { @MainActor in
            handler(modelID, error)
        }
    }
}
