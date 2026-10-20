import Foundation

struct ModelDownloadRecord: Equatable, Sendable {
    let option: ModelOption
    let destination: URL
}

struct ModelDownloadRegistry: Equatable, Sendable {
    private var infoByTaskID: [Int: ModelDownloadRecord] = [:]
    private var taskIDByModelID: [String: Int] = [:]

    var isEmpty: Bool {
        infoByTaskID.isEmpty && taskIDByModelID.isEmpty
    }

    var count: Int {
        infoByTaskID.count
    }

    mutating func track(taskID: Int, option: ModelOption, destination: URL) {
        if let oldTaskID = taskIDByModelID[option.id] {
            infoByTaskID.removeValue(forKey: oldTaskID)
        }

        infoByTaskID[taskID] = ModelDownloadRecord(option: option, destination: destination)
        taskIDByModelID[option.id] = taskID
    }

    func record(for taskID: Int) -> ModelDownloadRecord? {
        infoByTaskID[taskID]
    }

    func taskID(for modelID: String) -> Int? {
        taskIDByModelID[modelID]
    }

    @discardableResult
    mutating func cleanup(taskID: Int, modelID: String) -> ModelDownloadRecord? {
        let record = infoByTaskID.removeValue(forKey: taskID)

        if taskIDByModelID[modelID] == taskID {
            taskIDByModelID.removeValue(forKey: modelID)
        }

        return record
    }
}

struct WhisperDownloadIntent: Equatable, Sendable {
    let option: ModelOption
    let url: URL
    let generation: Int
}

struct WhisperPendingStart: Equatable, Sendable {
    let intent: WhisperDownloadIntent
    let fallbackResumeData: Data?
}

enum WhisperDownloadPreparation: Equatable, Sendable {
    /// Start immediately with stored resume bytes, if available.
    case start(WhisperPendingStart)
    /// Cancel the active task for resume bytes, then start this intent.
    case reclaim(WhisperPendingStart)
    /// A cancel callback already owns the active task and will start the
    /// atomically parked intent when its resume bytes arrive.
    case waitForCancellation
}

/// Lock-owned value state for Whisper task replacement, cancellation, resume
/// data, and delegate registry bookkeeping. It deliberately stores no closure:
/// Foundation's cancel callbacks capture only Sendable intent values, and the
/// cancel-in-flight check plus pending-start park happen in one critical
/// section so a restart cannot be stranded between them.
struct WhisperDownloadCoordinator: Sendable {
    private var registry = ModelDownloadRegistry()
    private var restartGeneration: [String: Int] = [:]
    private var pendingStart: [String: WhisperPendingStart] = [:]
    private var cancelInFlight: Set<String> = []
    private var resumeDataByModelID: [String: Data] = [:]
    private var generationByTaskID: [Int: Int] = [:]

    var pendingStartCount: Int { pendingStart.count }

    func isCancellationInFlight(for modelID: String) -> Bool {
        cancelInFlight.contains(modelID)
    }

    func storedResumeData(for modelID: String) -> Data? {
        resumeDataByModelID[modelID]
    }

    func currentGeneration(for modelID: String) -> Int? {
        restartGeneration[modelID]
    }

    mutating func prepareDownload(
        option: ModelOption,
        url: URL,
        replacingActiveTask: Bool
    ) -> WhisperDownloadPreparation {
        let generation = nextGeneration(for: option.id)
        let pending = WhisperPendingStart(
            intent: WhisperDownloadIntent(option: option, url: url, generation: generation),
            fallbackResumeData: resumeDataByModelID.removeValue(forKey: option.id)
        )

        if replacingActiveTask {
            return .reclaim(pending)
        }
        if cancelInFlight.contains(option.id) {
            // This park is atomic with observing cancelInFlight because the
            // manager calls us while holding its one state lock.
            pendingStart[option.id] = pending
            return .waitForCancellation
        }
        return .start(pending)
    }

    /// Invalidates every older request for this model. If no live task exists,
    /// a parked restart is still removed so an already-cancelled user intent
    /// cannot be revived by a late resume callback.
    mutating func prepareCancellation(modelID: String, hasActiveTask: Bool) -> Int {
        let generation = nextGeneration(for: modelID)
        pendingStart.removeValue(forKey: modelID)
        if hasActiveTask {
            cancelInFlight.insert(modelID)
        }
        return generation
    }

    /// Completes `cancel(byProducingResumeData:)`. A newer parked request owns
    /// the bytes; otherwise only the same cancel generation may retain them.
    mutating func completeCancellation(
        modelID: String,
        cancelGeneration: Int,
        resumeData: Data?
    ) -> WhisperPendingStart? {
        cancelInFlight.remove(modelID)

        if let pending = pendingStart.removeValue(forKey: modelID),
           restartGeneration[modelID] == pending.intent.generation {
            return WhisperPendingStart(
                intent: pending.intent,
                fallbackResumeData: resumeData ?? pending.fallbackResumeData
            )
        }

        if let resumeData, restartGeneration[modelID] == cancelGeneration {
            resumeDataByModelID[modelID] = resumeData
        }
        return nil
    }

    @discardableResult
    mutating func storeResumeData(
        _ data: Data,
        modelID: String,
        generation: Int
    ) -> Bool {
        guard restartGeneration[modelID] == generation else { return false }
        resumeDataByModelID[modelID] = data
        return true
    }

    mutating func clearResumeData(for modelID: String) {
        resumeDataByModelID.removeValue(forKey: modelID)
    }

    func accepts(_ intent: WhisperDownloadIntent) -> Bool {
        restartGeneration[intent.option.id] == intent.generation
    }

    mutating func trackTask(taskID: Int, intent: WhisperDownloadIntent, destination: URL) {
        registry.track(taskID: taskID, option: intent.option, destination: destination)
        generationByTaskID[taskID] = intent.generation
    }

    func record(for taskID: Int) -> ModelDownloadRecord? {
        registry.record(for: taskID)
    }

    func taskID(for modelID: String) -> Int? {
        registry.taskID(for: modelID)
    }

    func taskGeneration(for taskID: Int) -> Int? {
        generationByTaskID[taskID]
    }

    @discardableResult
    mutating func cleanupTask(taskID: Int, modelID: String) -> ModelDownloadRecord? {
        generationByTaskID.removeValue(forKey: taskID)
        return registry.cleanup(taskID: taskID, modelID: modelID)
    }

    private mutating func nextGeneration(for modelID: String) -> Int {
        let generation = restartGeneration[modelID, default: 0] + 1
        restartGeneration[modelID] = generation
        return generation
    }
}
