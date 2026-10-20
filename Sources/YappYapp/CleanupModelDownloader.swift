import Foundation

// LLM-CLEANUP (YA-10): downloads the pinned cleanup model with real progress
// and a cancel. The finished file is moved to a staging path before the
// delegate returns (URLSession deletes its temp file right after), then
// CleanupModelStore checks the SHA-1 and installs it. The only URL it ever
// fetches is its pinned `source`: LLMCleaner.model.downloadURL by default, or
// a TranslationCatalog download (round 2), whose SHA-256 TranslationModelStore
// checks the same way.
final class CleanupModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    typealias ProgressHandler = @MainActor @Sendable (Double?) -> Void
    typealias CompletionHandler = @MainActor @Sendable (Result<URL, Error>) -> Void

    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var onProgress: ProgressHandler?
    private var onCompletion: CompletionHandler?
    private var stagedFile: URL?
    private var stagingError: Error?
    private var lastReportedPercent = -1
    private let source: URL

    init(source: URL = LLMCleaner.model.downloadURL) {
        self.source = source
        super.init()
    }

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = ["User-Agent": "YappYapp/0.4"]
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 7_200
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return task != nil
    }

    /// Starts the download unless one is already running. Returns false when
    /// it was already running.
    @discardableResult
    func start(
        stagingURL: URL = CleanupModelStore.stagingURL,
        progress: @escaping ProgressHandler,
        completion: @escaping CompletionHandler
    ) -> Bool {
        lock.lock()
        guard task == nil else {
            lock.unlock()
            return false
        }
        let newTask = session.downloadTask(with: source)
        task = newTask
        onProgress = progress
        onCompletion = completion
        stagedFile = stagingURL
        stagingError = nil
        lastReportedPercent = -1
        lock.unlock()
        newTask.resume()
        return true
    }

    func cancel() {
        lock.lock()
        let running = task
        lock.unlock()
        running?.cancel()
    }

    /// Percent steps only, so the UI is not flooded with tiny updates.
    static func shouldReport(percent: Int, last: Int) -> Bool {
        percent != last
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let fraction = ModelDownloadManager.normalizedProgress(
            totalBytesWritten: totalBytesWritten,
            totalBytesExpectedToWrite: totalBytesExpectedToWrite
        )
        let percent = fraction.map { Int($0 * 100) } ?? -2
        lock.lock()
        guard downloadTask === task, Self.shouldReport(percent: percent, last: lastReportedPercent) else {
            lock.unlock()
            return
        }
        lastReportedPercent = percent
        let handler = onProgress
        lock.unlock()
        if let handler {
            Task { @MainActor in handler(fraction) }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        lock.lock()
        let destination = stagedFile
        lock.unlock()
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode
        var failure: Error?
        if let status, status != 200 {
            failure = CleanupModelError.httpStatus(status)
        } else if let destination {
            do {
                try PrivateFile.ensureDirectory(at: destination.deletingLastPathComponent())
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
            } catch {
                failure = error
            }
        }
        lock.lock()
        stagingError = failure
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task finished: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        guard finished === task else {
            lock.unlock()
            return
        }
        task = nil
        let handler = onCompletion
        let staged = stagedFile
        let stagingFailure = stagingError
        onProgress = nil
        onCompletion = nil
        lock.unlock()

        let result: Result<URL, Error>
        if let error {
            let canceled = (error as NSError).code == NSURLErrorCancelled
            result = .failure(canceled ? CleanupModelError.canceled : error)
        } else if let stagingFailure {
            result = .failure(stagingFailure)
        } else if let staged {
            result = .success(staged)
        } else {
            result = .failure(CleanupModelError.canceled)
        }
        if case .failure = result, let staged {
            try? FileManager.default.removeItem(at: staged)
        }
        if let handler {
            Task { @MainActor in handler(result) }
        }
    }
}
