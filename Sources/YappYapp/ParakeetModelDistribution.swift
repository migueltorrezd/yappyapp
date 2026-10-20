import FluidAudio
import Foundation

struct ParakeetDownloadPlan: Sendable {
    let variant: String
    let version: AsrModelVersion
    let repo: Repo
    let revision: String
    let requiredModelNames: Set<String>
    let auxiliaryFileNames: Set<String>
    let targetDirectory: URL
    let repoDirectory: URL
    let subPath: String?

    var integrityManifestURL: URL {
        repoDirectory.appendingPathComponent(".yappyapp-integrity-v1.json")
    }
}

enum ParakeetDigestAlgorithm: String, Codable, Equatable, Sendable {
    case sha256
    case gitBlobSHA1
}

struct ParakeetRemoteFile: Codable, Equatable, Sendable {
    let path: String
    let localPath: String
    let size: Int
    let digestAlgorithm: ParakeetDigestAlgorithm
    let digest: String
}

struct ParakeetCacheManifest: Codable, Equatable, Sendable {
    let schema: Int
    let repo: String
    let revision: String
    let files: [ParakeetRemoteFile]
}

struct HuggingFaceTreeItem: Decodable, Equatable, Sendable {
    struct LFS: Decodable, Equatable, Sendable {
        let oid: String
        let size: Int
    }

    let type: String
    let path: String
    let size: Int?
    let oid: String?
    let lfs: LFS?
}

/// Resolves the immutable Hugging Face tree for one Parakeet revision into a
/// validated local-file manifest. It owns listing only; cache mutation lives in
/// `ParakeetCacheInstaller`.
struct ParakeetManifestResolver: Sendable {
    private static let huggingFaceOrigin = "https://huggingface.co"
    private let session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    func resolve(plan: ParakeetDownloadPlan) async throws -> [ParakeetRemoteFile] {
        var files: [ParakeetRemoteFile] = []
        var seenRemotePaths: Set<String> = []
        var seenLocalPaths: Set<String> = []
        var visitedPages: Set<URL> = []
        var nextURL: URL? = try Self.firstPageURL(for: plan)

        while let url = nextURL {
            try Task.checkCancellation()
            guard visitedPages.insert(url).inserted, visitedPages.count <= 1_000 else {
                throw WhisperError.serverFailed(
                    "Pinned Parakeet manifest pagination was cyclic or unexpectedly large."
                )
            }

            let (data, response) = try await session.data(for: Self.request(url: url))
            guard let httpResponse = response as? HTTPURLResponse else {
                throw WhisperError.serverFailed("Received an invalid response from Hugging Face.")
            }
            if httpResponse.statusCode == 429 || httpResponse.statusCode == 503 {
                throw WhisperError.serverFailed(
                    "Hugging Face rate limit encountered while listing Parakeet files."
                )
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw WhisperError.serverFailed(
                    "Parakeet file listing returned HTTP \(httpResponse.statusCode)."
                )
            }

            let items: [HuggingFaceTreeItem]
            do {
                items = try JSONDecoder().decode([HuggingFaceTreeItem].self, from: data)
            } catch {
                throw WhisperError.serverFailed("Received an invalid Parakeet file listing.")
            }

            files.append(
                contentsOf: try Self.resolve(
                    items: items,
                    plan: plan,
                    seenRemotePaths: &seenRemotePaths,
                    seenLocalPaths: &seenLocalPaths
                )
            )
            nextURL = Self.nextPageURL(from: httpResponse)
        }

        return files
    }

    /// Pure page resolver used by the network path and focused manifest tests.
    static func resolve(
        items: [HuggingFaceTreeItem],
        plan: ParakeetDownloadPlan,
        seenRemotePaths: inout Set<String>,
        seenLocalPaths: inout Set<String>
    ) throws -> [ParakeetRemoteFile] {
        let modelPatterns = Set(plan.requiredModelNames.map { name in
            if let subPath = plan.subPath {
                return "\(subPath)/\(name)/"
            }
            return "\(name)/"
        })

        func shouldInclude(_ itemPath: String) -> Bool {
            let lastComponent = (itemPath as NSString).lastPathComponent
            if plan.auxiliaryFileNames.contains(lastComponent) {
                return true
            }
            return modelPatterns.contains { itemPath.hasPrefix($0) }
        }

        func localPath(for itemPath: String) -> String {
            if let subPath = plan.subPath, itemPath.hasPrefix("\(subPath)/") {
                return String(itemPath.dropFirst(subPath.count + 1))
            }
            return itemPath
        }

        var resolved: [ParakeetRemoteFile] = []
        for item in items {
            guard item.type == "file",
                  shouldInclude(item.path),
                  !seenRemotePaths.contains(item.path),
                  let size = item.size,
                  size >= 0,
                  let oid = item.oid,
                  !oid.isEmpty
            else { continue }

            let local = localPath(for: item.path)
            guard isSafeRelativeModelPath(local) else {
                throw WhisperError.serverFailed("Pinned Parakeet manifest contained an unsafe path.")
            }
            guard seenLocalPaths.insert(local).inserted else {
                throw WhisperError.serverFailed(
                    "Pinned Parakeet manifest mapped multiple files to the same cache path."
                )
            }

            let algorithm: ParakeetDigestAlgorithm
            let digest: String
            if let lfs = item.lfs {
                guard lfs.size == size, isValidHexDigest(lfs.oid, length: 64) else {
                    throw WhisperError.serverFailed(
                        "Pinned Parakeet LFS metadata was inconsistent for \(item.path)."
                    )
                }
                algorithm = .sha256
                digest = lfs.oid.lowercased()
            } else {
                guard isValidHexDigest(oid, length: 40) else {
                    throw WhisperError.serverFailed(
                        "Pinned Parakeet Git metadata was inconsistent for \(item.path)."
                    )
                }
                algorithm = .gitBlobSHA1
                digest = oid.lowercased()
            }

            seenRemotePaths.insert(item.path)
            resolved.append(
                ParakeetRemoteFile(
                    path: item.path,
                    localPath: local,
                    size: size,
                    digestAlgorithm: algorithm,
                    digest: digest
                )
            )
        }
        return resolved
    }

    static func isSafeRelativeModelPath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.contains("\0")
        else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    static func isValidHexDigest(_ digest: String, length: Int) -> Bool {
        guard digest.count == length else { return false }
        return digest.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value)
                || (65...70).contains(scalar.value)
                || (97...102).contains(scalar.value)
        }
    }

    static func nextPageURL(from response: HTTPURLResponse) -> URL? {
        guard let link = response.value(forHTTPHeaderField: "Link") else { return nil }
        for entry in link.split(separator: ",") {
            guard entry.contains("rel=\"next\"") || entry.contains("rel=next") else { continue }
            guard let start = entry.firstIndex(of: "<"),
                  let end = entry[start...].firstIndex(of: ">"),
                  start < end
            else {
                continue
            }
            guard let candidate = URL(string: String(entry[entry.index(after: start)..<end])),
                  candidate.scheme == "https",
                  candidate.host == "huggingface.co",
                  candidate.host == response.url?.host,
                  candidate.user == nil,
                  candidate.password == nil,
                  candidate.port == nil,
                  candidate.path.hasPrefix("/api/models/")
            else {
                continue
            }
            return candidate
        }
        return nil
    }

    static func pinnedResolveURL(
        file: ParakeetRemoteFile,
        plan: ParakeetDownloadPlan
    ) throws -> URL {
        var pathCharacters = CharacterSet.urlPathAllowed
        pathCharacters.remove(charactersIn: "?#%")
        guard let encodedPath = file.path.addingPercentEncoding(withAllowedCharacters: pathCharacters) else {
            throw WhisperError.serverFailed("Could not encode a pinned Parakeet file path.")
        }
        let value = "\(huggingFaceOrigin)/\(plan.repo.remotePath)/resolve/\(plan.revision)/\(encodedPath)"
        guard let url = URL(string: value) else {
            throw WhisperError.serverFailed("Could not construct pinned Parakeet file URL.")
        }
        return url
    }

    static func request(url: URL) -> URLRequest {
        // All pinned release models are public. Never attach ambient Hugging
        // Face credentials to model requests or their CDN redirects.
        URLRequest(url: url, timeoutInterval: 1_800)
    }

    private static func firstPageURL(for plan: ParakeetDownloadPlan) throws -> URL {
        guard let baseURL = URL(
            string: "\(huggingFaceOrigin)/api/models/\(plan.repo.remotePath)/tree/\(plan.revision)"
        ),
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else {
            throw WhisperError.serverFailed("Could not construct the pinned Parakeet manifest URL.")
        }
        components.queryItems = [
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "expand", value: "false")
        ]
        guard let url = components.url else {
            throw WhisperError.serverFailed("Could not construct the pinned Parakeet manifest URL.")
        }
        return url
    }
}

/// Validates and publishes the small trust manifest that marks a complete,
/// pinned Parakeet cache as safe to load.
enum ParakeetCacheRegistry {
    static let schema = 1

    static func isVerified(plan: ParakeetDownloadPlan) -> Bool {
        guard AsrModels.modelsExist(
            at: plan.targetDirectory,
            version: plan.version,
            encoderPrecision: .int8
        ),
        let data = try? Data(contentsOf: plan.integrityManifestURL),
        let manifest = try? JSONDecoder().decode(ParakeetCacheManifest.self, from: data),
        validates(manifest: manifest, plan: plan)
        else {
            return false
        }

        return manifest.files.allSatisfy { file in
            let url = plan.repoDirectory.appendingPathComponent(file.localPath)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber
            else {
                return false
            }
            return size.intValue == file.size
        }
    }

    static func validates(
        manifest: ParakeetCacheManifest,
        plan: ParakeetDownloadPlan
    ) -> Bool {
        guard manifest.schema == schema,
              manifest.repo == plan.repo.remotePath,
              manifest.revision == plan.revision,
              !manifest.files.isEmpty
        else {
            return false
        }

        var localPaths: Set<String> = []
        return manifest.files.allSatisfy { file in
            file.size >= 0
                && ParakeetManifestResolver.isSafeRelativeModelPath(file.localPath)
                && localPaths.insert(file.localPath).inserted
        }
    }

    static func encodedManifest(
        plan: ParakeetDownloadPlan,
        files: [ParakeetRemoteFile]
    ) throws -> Data {
        let manifest = ParakeetCacheManifest(
            schema: schema,
            repo: plan.repo.remotePath,
            revision: plan.revision,
            files: files.sorted { $0.localPath < $1.localPath }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(manifest)
    }
}

/// Serializes only cache publication. Transfers and checksum work remain
/// concurrent, but two downloads can never remove or replace the same final
/// cache file at the same time.
fileprivate actor ParakeetCachePublishGate {
    func publish(
        temporaryURL: URL,
        destination: URL,
        metadata: ParakeetRemoteFile
    ) throws {
        try Task.checkCancellation()

        if FileManager.default.fileExists(atPath: destination.path) {
            if (try? ModelIntegrity.verifyParakeetFile(at: destination, metadata: metadata)) != nil {
                return
            }
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
    }

    func publishManifest(_ data: Data, to destination: URL) throws {
        try Task.checkCancellation()
        try PrivateFile.write(data, to: destination)
    }
}

/// Downloads and verifies resolved Parakeet files, then atomically publishes
/// the pinned cache manifest. The session and publish gate are immutable
/// instance dependencies, so no mutable process-global transport state exists.
struct ParakeetCacheInstaller: Sendable {
    private let session: URLSession
    private let publishGate: ParakeetCachePublishGate

    fileprivate init(session: URLSession, publishGate: ParakeetCachePublishGate) {
        self.session = session
        self.publishGate = publishGate
    }

    func install(
        files: [ParakeetRemoteFile],
        plan: ParakeetDownloadPlan,
        progress: @escaping @Sendable (ParakeetDownloadProgress) -> Void
    ) async throws {
        guard !files.isEmpty else {
            throw WhisperError.serverFailed(
                "Pinned Parakeet manifest did not contain any required files."
            )
        }

        let missingFiles = files.filter { file in
            let destination = plan.repoDirectory.appendingPathComponent(file.localPath)
            guard FileManager.default.fileExists(atPath: destination.path) else { return true }
            return (try? ModelIntegrity.verifyParakeetFile(at: destination, metadata: file)) == nil
        }
        let totalBytes = missingFiles.reduce(Int64(0)) { $0 + Int64(max(0, $1.size)) }
        var completedFiles = 0
        // YA-51: progress moves with every chunk received, not file by file.
        let byteProgress = ParakeetByteProgress(totalBytes: totalBytes)

        progress(ParakeetDownloadProgress(fraction: 0, phase: .downloading))
        try await withThrowingTaskGroup(of: Int64.self) { group in
            for file in missingFiles {
                group.addTask {
                    try await download(file: file, plan: plan) { received in
                        byteProgress.update(file: file.path, receivedBytes: received, expectedBytes: Int64(max(0, file.size)))
                        if let fraction = byteProgress.fractionToReport() {
                            progress(ParakeetDownloadProgress(fraction: fraction, phase: .downloading))
                        }
                    }
                }
            }

            for try await _ in group {
                completedFiles += 1
                let fraction: Double
                if totalBytes > 0 {
                    fraction = byteProgress.fraction
                } else {
                    fraction = Double(completedFiles) / Double(max(1, missingFiles.count))
                }
                progress(
                    ParakeetDownloadProgress(
                        fraction: min(max(fraction, 0), 1),
                        phase: .downloading
                    )
                )
            }
        }

        try Task.checkCancellation()
        for file in files {
            let destination = plan.repoDirectory.appendingPathComponent(file.localPath)
            try ModelIntegrity.verifyParakeetFile(at: destination, metadata: file)
        }

        guard AsrModels.modelsExist(
            at: plan.targetDirectory,
            version: plan.version,
            encoderPrecision: .int8
        ) else {
            throw WhisperError.serverFailed("Parakeet download finished with missing model files.")
        }

        let manifestData = try ParakeetCacheRegistry.encodedManifest(plan: plan, files: files)
        try await publishGate.publishManifest(manifestData, to: plan.integrityManifestURL)
        progress(ParakeetDownloadProgress(fraction: 1, phase: .downloading))
    }

    private func download(
        file: ParakeetRemoteFile,
        plan: ParakeetDownloadPlan,
        onBytes: @escaping @Sendable (Int64) -> Void
    ) async throws -> Int64 {
        try Task.checkCancellation()
        let destination = plan.repoDirectory.appendingPathComponent(file.localPath)
        if FileManager.default.fileExists(atPath: destination.path),
           (try? ModelIntegrity.verifyParakeetFile(at: destination, metadata: file)) != nil {
            onBytes(Int64(max(0, file.size)))
            return Int64(max(0, file.size))
        }

        try Self.createDownloadDirectory(at: destination.deletingLastPathComponent())

        let temporaryURL: URL
        if file.size == 0 {
            temporaryURL = destination.deletingLastPathComponent()
                .appendingPathComponent(".yappyapp-download-\(UUID().uuidString)")
            try Data().write(to: temporaryURL, options: .atomic)
        } else {
            let url = try ParakeetManifestResolver.pinnedResolveURL(file: file, plan: plan)
            let (downloadedURL, response) = try await ProgressReportingDownload.download(
                session: session,
                request: ParakeetManifestResolver.request(url: url),
                onBytes: onBytes
            )
            guard let httpResponse = response as? HTTPURLResponse else {
                throw WhisperError.serverFailed(
                    "Received an invalid response while downloading \(file.path)."
                )
            }
            if httpResponse.statusCode == 429 || httpResponse.statusCode == 503 {
                throw WhisperError.serverFailed(
                    "Hugging Face rate limit encountered while downloading \(file.path)."
                )
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw WhisperError.serverFailed(
                    "Parakeet file download returned HTTP \(httpResponse.statusCode)."
                )
            }
            temporaryURL = downloadedURL
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        onBytes(Int64(max(0, file.size)))

        try Task.checkCancellation()
        try ModelIntegrity.verifyParakeetFile(at: temporaryURL, metadata: file)
        try await publishGate.publish(
            temporaryURL: temporaryURL,
            destination: destination,
            metadata: file
        )
        return Int64(max(0, file.size))
    }

    private static func createDownloadDirectory(at url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue { return }
            throw WhisperError.serverFailed(
                "A model cache path expected to be a directory is occupied by a file."
            )
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

enum ParakeetModelDistribution {
    /// One immutable actor reference serializes final cache publication across
    /// every concurrent model request without introducing mutable static state.
    private static let publishGate = ParakeetCachePublishGate()

    static func plan(for variant: String) -> ParakeetDownloadPlan {
        let version = asrVersion(forVariant: variant)
        let repo: Repo
        let revision: String
        let requiredModelNames: Set<String>
        let auxiliaryFileNames: Set<String>

        switch variant {
        case "v2":
            repo = .parakeetV2
            revision = "ee09c569f73759e6d44c9bd16766f477b2b36d39"
            requiredModelNames = ModelNames.ASR.requiredModels
            auxiliaryFileNames = [ModelNames.ASR.vocabularyFile]
        case "tdtCtc110m":
            repo = .parakeetTdtCtc110m
            revision = "9bc92ead6e8f17eca92a869fd578ae76842b82ba"
            requiredModelNames = ModelNames.ASR.requiredModelsFused
            auxiliaryFileNames = [ModelNames.ASR.vocabularyFile]
        case "ultra":
            // Parakeet Ultra keeps the v3 file contract (one int8 encoder,
            // JointDecisionv3, the v3 vocabulary) in its own repository.
            repo = .parakeetUltra
            revision = "95eaa59a39d4394f047a4dc5cce480388a60d1b6"
            requiredModelNames = ModelNames.ASR.requiredModelsV3()
            auxiliaryFileNames = [ModelNames.ASR.vocabularyFile]
        case "tdtJa":
            repo = .parakeetJa
            revision = "2952296ff1da4a6d6a7aec545e226367db80c612"
            requiredModelNames = ModelNames.TDTJa.requiredModels
            auxiliaryFileNames = [ModelNames.TDTJa.vocabularyFile]
        default:
            repo = .parakeetV3
            revision = "aed02740059203c4a87495924f685de3722ae9ce"
            requiredModelNames = ModelNames.ASR.requiredModelsV3(precision: .int8)
            auxiliaryFileNames = [ModelNames.ASR.vocabularyFile]
        }

        let targetDirectory = AsrModels.defaultCacheDirectory(for: version)
        return ParakeetDownloadPlan(
            variant: variant,
            version: version,
            repo: repo,
            revision: revision,
            requiredModelNames: requiredModelNames,
            auxiliaryFileNames: auxiliaryFileNames,
            targetDirectory: targetDirectory,
            repoDirectory: targetDirectory.deletingLastPathComponent().appendingPathComponent(repo.folderName),
            subPath: repo.subPath
        )
    }

    static func isVerifiedCache(variant: String) -> Bool {
        ParakeetCacheRegistry.isVerified(plan: plan(for: variant))
    }

    static func download(
        variant: String,
        progress: @escaping @Sendable (ParakeetDownloadProgress) -> Void
    ) async throws {
        let plan = plan(for: variant)
        let session = makeSession()
        // YA-51: a session holds its configuration, connection pool and
        // delegate queue until it is invalidated. One per download, so it is
        // released when this download ends, success or not.
        defer { session.finishTasksAndInvalidate() }
        let resolver = ParakeetManifestResolver(session: session)
        let installer = ParakeetCacheInstaller(session: session, publishGate: publishGate)

        progress(ParakeetDownloadProgress(fraction: 0, phase: .listing))
        let files = try await resolver.resolve(plan: plan)
        try await installer.install(files: files, plan: plan, progress: progress)
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.allowsConstrainedNetworkAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.httpAdditionalHeaders = ["User-Agent": "YappYapp/0.2"]
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.networkServiceType = .responsiveData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 14_400
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }
}

/// YA-51: downloads one file to a private temporary location while reporting
/// received bytes as they arrive. `URLSession.download(for:)` only reports
/// once a file is complete, which made the bar jump file by file. The task's
/// own byte counters are sampled while it runs; cancelling the Swift task
/// cancels the transfer.
enum ProgressReportingDownload {
    static let samplingInterval: TimeInterval = 0.25

    static func download(
        session: URLSession,
        request: URLRequest,
        onBytes: @escaping @Sendable (_ received: Int64) -> Void
    ) async throws -> (URL, URLResponse) {
        let box = DownloadTaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: request) { location, response, error in
                    box.stopSampling()
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let location, let response else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                        return
                    }
                    // The system deletes `location` when this handler returns.
                    let kept = FileManager.default.temporaryDirectory
                        .appendingPathComponent("yappyapp-parakeet-\(UUID().uuidString)")
                    do {
                        try FileManager.default.moveItem(at: location, to: kept)
                        continuation.resume(returning: (kept, response))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                box.start(task: task, interval: samplingInterval, onBytes: onBytes)
            }
        } onCancel: {
            box.cancel()
        }
    }
}

private final class DownloadTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDownloadTask?
    private var timer: DispatchSourceTimer?
    private var cancelled = false

    func start(task: URLSessionDownloadTask, interval: TimeInterval, onBytes: @escaping @Sendable (Int64) -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak task] in
            guard let task else { return }
            onBytes(task.countOfBytesReceived)
        }

        lock.lock()
        self.task = task
        self.timer = timer
        let alreadyCancelled = cancelled
        lock.unlock()

        timer.resume()
        task.resume()
        if alreadyCancelled {
            task.cancel()
        }
    }

    func stopSampling() {
        lock.lock()
        let timer = self.timer
        self.timer = nil
        lock.unlock()
        timer?.cancel()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}
