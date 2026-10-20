import Foundation

struct PetStats: Codable, Equatable {
    /// Version of the on-disk stats schema. Files written before versioning
    /// have no key and decode as schema 0 so PetStatsStore can migrate them
    /// explicitly instead of silently treating them as current forever.
    static let currentSchemaVersion = 1
    var schemaVersion = PetStats.currentSchemaVersion
    var totalWords = 0
    var wordsToday = 0
    var streakDays = 0
    var bestStreak = 0
    var lastDictationDay = ""
    var wordsByPet: [String: Int] = [:]
    var totalDictations = 0
    var dictationsToday = 0
    var earlyDay = ""
    var glossaryTaughtDay = ""
    var questCompletedDay = ""
    var streakSaverWeek = ""
    var milestonesHit: [Int] = []
    var eggStartWords: [String: Int] = [:]
    var weekWords = 0
    var weekKey = ""
    var starter = ""
    var questsCompletedTotal = 0
    var accessoriesByPet: [String: String] = [:]
    var journeyStartWords = 0
    var journeyStartDictations = 0
    var journeyStartQuests = 0
    var journeyStartDay = ""
    var journeyBestStreak = 0

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case totalWords, wordsToday, streakDays, bestStreak, lastDictationDay, wordsByPet
        case totalDictations, dictationsToday, earlyDay, glossaryTaughtDay, questCompletedDay
        case streakSaverWeek, milestonesHit, eggStartWords, weekWords, weekKey
        case starter, questsCompletedTotal, accessoriesByPet
        case journeyStartWords, journeyStartDictations, journeyStartQuests
        case journeyStartDay, journeyBestStreak
    }

    init() {}

    // Older stats files lack the newer keys; decode everything with defaults.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        totalWords = try container.decodeIfPresent(Int.self, forKey: .totalWords) ?? 0
        wordsToday = try container.decodeIfPresent(Int.self, forKey: .wordsToday) ?? 0
        streakDays = try container.decodeIfPresent(Int.self, forKey: .streakDays) ?? 0
        bestStreak = try container.decodeIfPresent(Int.self, forKey: .bestStreak) ?? streakDays
        lastDictationDay = try container.decodeIfPresent(String.self, forKey: .lastDictationDay) ?? ""
        wordsByPet = try container.decodeIfPresent([String: Int].self, forKey: .wordsByPet) ?? [:]
        totalDictations = try container.decodeIfPresent(Int.self, forKey: .totalDictations) ?? 0
        dictationsToday = try container.decodeIfPresent(Int.self, forKey: .dictationsToday) ?? 0
        earlyDay = try container.decodeIfPresent(String.self, forKey: .earlyDay) ?? ""
        glossaryTaughtDay = try container.decodeIfPresent(String.self, forKey: .glossaryTaughtDay) ?? ""
        questCompletedDay = try container.decodeIfPresent(String.self, forKey: .questCompletedDay) ?? ""
        streakSaverWeek = try container.decodeIfPresent(String.self, forKey: .streakSaverWeek) ?? ""
        milestonesHit = try container.decodeIfPresent([Int].self, forKey: .milestonesHit) ?? []
        eggStartWords = try container.decodeIfPresent([String: Int].self, forKey: .eggStartWords) ?? [:]
        weekWords = try container.decodeIfPresent(Int.self, forKey: .weekWords) ?? 0
        weekKey = try container.decodeIfPresent(String.self, forKey: .weekKey) ?? ""
        starter = try container.decodeIfPresent(String.self, forKey: .starter) ?? ""
        questsCompletedTotal = try container.decodeIfPresent(Int.self, forKey: .questsCompletedTotal) ?? 0
        accessoriesByPet = try container.decodeIfPresent([String: String].self, forKey: .accessoriesByPet) ?? [:]
        journeyStartWords = try container.decodeIfPresent(Int.self, forKey: .journeyStartWords) ?? 0
        journeyStartDictations = try container.decodeIfPresent(Int.self, forKey: .journeyStartDictations) ?? 0
        journeyStartQuests = try container.decodeIfPresent(Int.self, forKey: .journeyStartQuests) ?? 0
        journeyStartDay = try container.decodeIfPresent(String.self, forKey: .journeyStartDay) ?? ""
        journeyBestStreak = try container.decodeIfPresent(Int.self, forKey: .journeyBestStreak) ?? 0
    }

    func words(for pet: PetKind) -> Int {
        wordsByPet[pet.rawValue] ?? 0
    }

    /// YA-30: the day that counts as "today" for counters, streaks and quests.
    /// Travelling west across midnight moves the wall clock day back by one;
    /// the stats keep counting on the later day already recorded, so the
    /// streak is not reset and the same quest cannot complete twice. A jump
    /// back of more than one day is a clock correction, so the wall clock wins.
    func effectiveDay(asOf now: Date = Date()) -> String {
        let today = PetStatsStore.dayString(now)
        let latest = [lastDictationDay, questCompletedDay].max() ?? ""
        guard let difference = PetStatsStore.signedDaysBetween(latest, and: today),
              difference == -1 else {
            return today
        }
        return latest
    }

    /// A Date inside the effective day: `now` itself when the wall clock day
    /// is the effective day, otherwise noon of the recorded later day.
    func effectiveAnchor(asOf now: Date = Date()) -> Date {
        let day = effectiveDay(asOf: now)
        guard day != PetStatsStore.dayString(now) else { return now }
        return PetStatsStore.noon(ofDay: day) ?? now
    }

    // FIX staleDayDisplay: the stored day/week counters only roll over inside
    // PetStatsStore.record(), so a view that opens on a new day (or after a
    // gap) would otherwise render yesterday's "Today"/week numbers and a
    // streak that is already broken. These read accessors normalize against
    // `now` so the UI never claims a stale count as current.

    /// Words dictated today, or 0 once the calendar day has moved past the day
    /// the counter was written for.
    func wordsTodayDisplayed(asOf now: Date = Date()) -> Int {
        lastDictationDay == effectiveDay(asOf: now) ? wordsToday : 0
    }

    /// Dictations completed today, or 0 after the day rolls over.
    func dictationsTodayDisplayed(asOf now: Date = Date()) -> Int {
        lastDictationDay == effectiveDay(asOf: now) ? dictationsToday : 0
    }

    /// Current streak, or 0 once it is already broken: a streak that was not
    /// extended today or yesterday no longer counts, even though record() only
    /// resets streakDays on the next dictation. YA-67: a single missed day
    /// still shows the streak while this week's streak saver is unused,
    /// because a dictation today would keep it alive.
    func streakDisplayed(asOf now: Date = Date()) -> Int {
        let today = effectiveDay(asOf: now)
        let anchor = effectiveAnchor(asOf: now)
        guard let gap = PetStatsStore.signedDaysBetween(lastDictationDay, and: today) else { return 0 }
        switch gap {
        case 0, 1:
            return streakDays
        case 2:
            return streakSaverWeek != PetStatsStore.weekString(anchor) ? streakDays : 0
        default:
            return 0
        }
    }

    /// Words dictated this week, or 0 once the week key no longer matches the
    /// current week.
    func weekWordsDisplayed(asOf now: Date = Date()) -> Int {
        weekKey == PetStatsStore.weekString(effectiveAnchor(asOf: now)) ? weekWords : 0
    }

    /// Highest level reached by any pet; gates the late-game unlocks.
    var maxPetLevel: Int {
        wordsByPet.values.map(petLevel(forWords:)).max() ?? 1
    }

    func accessory(for pet: PetKind) -> PetAccessory {
        let stored = PetAccessory(rawValue: accessoriesByPet[pet.rawValue] ?? "none") ?? .none
        guard stored != .none else { return .none }
        // FIX journeyWardrobeRegate: a journey reset wipes per-pet XP but the
        // equipped accessory can linger (older saves, or a future path that
        // forgets to clear it), leaving e.g. a level-10 halo on a level-1 pet.
        // Re-gate at read time against the same unlock rule the wardrobe uses,
        // so an accessory the pet can no longer afford simply does not show.
        return petLevel(forWords: words(for: pet)) >= stored.unlockLevel ? stored : .none
    }

    /// Progress earned since the starter was chosen. Lifetime history from
    /// before the journey began never unlocks pets.
    var journeyWords: Int { max(0, totalWords - journeyStartWords) }
    var journeyDictations: Int { max(0, totalDictations - journeyStartDictations) }
    var journeyQuests: Int { max(0, questsCompletedTotal - journeyStartQuests) }

    /// Snapshot the lifetime counters and wipe per-pet XP: the Pokémon
    /// journey starts the moment the starter is chosen. YA-68: migrating an
    /// old save keeps the XP each pet already earned (`keepingPetXP`).
    mutating func beginJourney(day: String, keepingPetXP: Bool = false) {
        journeyStartWords = totalWords
        journeyStartDictations = totalDictations
        journeyStartQuests = questsCompletedTotal
        journeyStartDay = day
        journeyBestStreak = 0
        // Equipped accessories are re-gated by accessory(for:), so keeping
        // them alongside kept XP is safe.
        guard !keepingPetXP else { return }
        wordsByPet = [:]
        // Fresh journey means every pet is back to level 1, so nothing in the
        // wardrobe is earned yet. Clear equips alongside XP so an old accessory
        // does not survive on a re-leveled pet. accessory(for:) also re-gates
        // at read time for saves that predate this clear.
        accessoriesByPet = [:]
    }

    /// Pokémon rules: the chosen starter is yours; everything else is earned
    /// through its own quest, counted from the journey start.
    func isUnlocked(_ kind: PetKind) -> Bool {
        guard kind != .none else { return true }
        // No starter, no journey: nothing else can unlock yet.
        guard !starter.isEmpty else { return false }

        // The chosen starter is yours; everything else, the other starters
        // included, is earned through its requirement (PetUnlocks.swift).
        if starter == kind.rawValue { return true }
        guard let requirement = kind.unlockRequirement else { return true }
        return requirement.isMet(in: self)
    }

    /// Words contributed toward hatching a newly unlocked pet's egg.
    func hatchProgress(_ kind: PetKind) -> Int {
        guard let start = eggStartWords[kind.rawValue] else { return 0 }
        return min(PetStats.hatchTarget, max(0, totalWords - start))
    }

    /// Every pet, the starter included, stays an egg until 300 words are
    /// dictated after it was first selected.
    func isEggPhase(_ kind: PetKind) -> Bool {
        guard kind != .none, isUnlocked(kind) else { return false }
        guard eggStartWords[kind.rawValue] != nil else { return true }
        return hatchProgress(kind) < PetStats.hatchTarget
    }

    static let hatchTarget = 300
    static let milestoneThresholds = [1_000, 10_000, 100_000]
}

enum PetStatsPersistenceOperation: String, Equatable {
    case loadPrimary
    case loadBackup
    case harden
    case quarantine
    case backup
    case save
}

struct PetStatsPersistenceIssue: Equatable {
    let operation: PetStatsPersistenceOperation
    let filename: String
    let message: String
}

enum PetStatsRecovery: Equatable {
    case restoredFromBackup(quarantinedFilename: String?)
    case restoredDefaults(quarantinedFilename: String?)
}

enum PetStatsPersistenceError: LocalizedError, Equatable {
    case unsupportedSchemaVersion(Int)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchemaVersion(version):
            return "unsupported pet stats schema version \(version)"
        }
    }
}

struct PetStatsMigrationResult: Equatable {
    let stats: PetStats
    let originalSchemaVersion: Int

    var didMigrate: Bool {
        originalSchemaVersion != PetStats.currentSchemaVersion
    }
}

private struct PetStatsDiskLoadResult {
    let stats: PetStats
    let needsRewrite: Bool
    let shouldRotateBackup: Bool
    let migratedFromSchemaVersion: Int?
}

/// Pets level up every 250 dictated words while they are the active pet.
func petLevel(forWords words: Int) -> Int {
    1 + words / 250
}

enum PetEvent: Equatable {
    case milestone(Int)
    case questCompleted
    case levelUp(Int)
    case unlocked(PetKind)
    case hatched(PetKind)
    case streakSaved
}

/// One quest per day, picked deterministically from the date.
enum DailyQuest: String, CaseIterable {
    case threeHundredWords
    case fiveDictations
    case teachAWord
    case earlyBird

    static func forDay(_ day: String) -> DailyQuest {
        let hash = day.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return allCases[hash % allCases.count]
    }

    var title: String {
        switch self {
        case .threeHundredWords: L10n.tr("Dictate 300 words")
        case .fiveDictations: L10n.tr("Finish 5 dictations")
        case .teachAWord: L10n.tr("Teach your pet a word (save one in WORDS)")
        case .earlyBird: L10n.tr("Dictate something before 10:00")
        }
    }

    var target: Int {
        switch self {
        case .threeHundredWords: 300
        case .fiveDictations: 5
        case .teachAWord, .earlyBird: 1
        }
    }

    func progress(in stats: PetStats, day: String) -> Int {
        // FIX questStaleRollover: the day-scoped counters only mean anything on
        // the day they were written. Reading yesterday's wordsToday against
        // today's quest would falsely advance (and even auto-complete) it, so
        // gate the day counters on the day key before comparing to the target.
        let countsForDay = stats.lastDictationDay == day
        switch self {
        case .threeHundredWords: return min(countsForDay ? stats.wordsToday : 0, target)
        case .fiveDictations: return min(countsForDay ? stats.dictationsToday : 0, target)
        case .teachAWord: return stats.glossaryTaughtDay == day ? 1 : 0
        case .earlyBird: return stats.earlyDay == day ? 1 : 0
        }
    }
}

/// Persists dictation counters that feed the pet's mood, levels, quests, and
/// unlocks. Numbers only, never text.
final class PetStatsStore {
    private(set) var stats: PetStats
    private(set) var lastEvents: [PetEvent] = []
    /// Sticky diagnostics for this store instance. A successful recovery does
    /// not erase the failure that caused it, so support tooling and tests can
    /// distinguish a clean load from a repaired one.
    private(set) var persistenceIssues: [PetStatsPersistenceIssue] = []
    private(set) var recovery: PetStatsRecovery?
    private(set) var migratedFromSchemaVersion: Int?
    /// YA-66: set when the file on disk was written by a newer YappYapp. The
    /// stats are shown as they are, nothing mutates them, and nothing is
    /// written, so a later upgrade finds the newer data untouched.
    private(set) var readOnlySchemaVersion: Int?
    private let url: URL

    var isReadOnly: Bool { readOnlySchemaVersion != nil }

    var lastLoadFailure: PetStatsPersistenceIssue? {
        persistenceIssues.last {
            $0.operation == .loadPrimary || $0.operation == .loadBackup
        }
    }

    var lastSaveFailure: PetStatsPersistenceIssue? {
        persistenceIssues.last {
            $0.operation == .backup || $0.operation == .save
        }
    }

    init(url: URL? = nil) {
        self.url = url ?? AppPaths.supportDirectory.appendingPathComponent("stats.json")
        stats = PetStats()

        let loadResult = loadFromDisk()
        stats = loadResult.stats
        migratedFromSchemaVersion = loadResult.migratedFromSchemaVersion
        var needsRewrite = loadResult.needsRewrite
        var migratedJourney = false

        // Saves from before journey tracking measured unlocks against
        // lifetime history, so old counters pre-unlocked half the roster.
        // Restart the journey from the current counters: only the starter
        // egg remains, everything else re-locks until earned. YA-68: per-pet
        // XP was earned, so it stays.
        if !isReadOnly, !stats.starter.isEmpty, stats.journeyStartDay.isEmpty {
            stats.beginJourney(day: Self.dayString(Date()), keepingPetXP: true)
            stats.eggStartWords = [stats.starter: stats.totalWords]
            needsRewrite = true
            migratedJourney = true
        }

        // YA-68: keep the exact pre-migration bytes in a file the rotating
        // backup never touches, so the next save cannot overwrite them.
        if recovery == nil, migratedJourney || loadResult.migratedFromSchemaVersion != nil {
            preserveMigrationSource()
        }

        if needsRewrite {
            save(rotatingBackup: loadResult.shouldRotateBackup)
        }
    }

    static func backupURL(for primaryURL: URL) -> URL {
        URL(fileURLWithPath: primaryURL.path + ".backup")
    }

    /// One-time copy of the file as it was before a migration rewrote it.
    static func migrationBackupURL(for primaryURL: URL) -> URL {
        URL(fileURLWithPath: primaryURL.path + ".pre-migration")
    }

    private func preserveMigrationSource() {
        let target = Self.migrationBackupURL(for: url)
        guard !FileManager.default.fileExists(atPath: target.path),
              let original = try? Data(contentsOf: url) else { return }
        do {
            try PrivateFile.write(original, to: target)
        } catch {
            recordIssue(operation: .backup, at: target, error: error)
        }
    }

    /// YA-66: a file from a newer schema is kept and shown read-only instead
    /// of being quarantined and replaced with empty stats.
    private func newerSchemaVersion(in error: Error) -> Int? {
        guard case let PetStatsPersistenceError.unsupportedSchemaVersion(version) = error,
              version > PetStats.currentSchemaVersion else { return nil }
        return version
    }

    private func readOnlyResult(_ data: Data, version: Int, from fileURL: URL) -> PetStatsDiskLoadResult {
        readOnlySchemaVersion = version
        var presented = (try? JSONDecoder().decode(PetStats.self, from: data)) ?? PetStats()
        presented.schemaVersion = version
        writeDiagnostic(
            "\(fileURL.lastPathComponent) uses pet stats schema \(version), newer than \(PetStats.currentSchemaVersion); kept read-only"
        )
        return PetStatsDiskLoadResult(
            stats: presented,
            needsRewrite: false,
            shouldRotateBackup: false,
            migratedFromSchemaVersion: nil
        )
    }

    /// Pure decode-and-migrate boundary used by both primary and backup loads.
    /// Schema 0 is the unversioned format shipped before persistence hardening;
    /// each future schema gets an explicit step here rather than relying on
    /// Codable's missing-key defaults as an accidental migration policy.
    static func decodeAndMigrate(_ data: Data) throws -> PetStatsMigrationResult {
        var decoded = try JSONDecoder().decode(PetStats.self, from: data)
        let originalVersion = decoded.schemaVersion

        while decoded.schemaVersion < PetStats.currentSchemaVersion {
            switch decoded.schemaVersion {
            case 0:
                decoded.schemaVersion = 1
            default:
                throw PetStatsPersistenceError.unsupportedSchemaVersion(decoded.schemaVersion)
            }
        }

        guard decoded.schemaVersion == PetStats.currentSchemaVersion else {
            throw PetStatsPersistenceError.unsupportedSchemaVersion(decoded.schemaVersion)
        }

        return PetStatsMigrationResult(
            stats: decoded,
            originalSchemaVersion: originalVersion
        )
    }

    static func encodedCurrentStats(_ stats: PetStats) throws -> Data {
        var current = stats
        current.schemaVersion = PetStats.currentSchemaVersion
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(current)
    }

    private func loadFromDisk() -> PetStatsDiskLoadResult {
        let fileManager = FileManager.default
        let backupURL = Self.backupURL(for: url)

        guard fileManager.fileExists(atPath: url.path) else {
            guard fileManager.fileExists(atPath: backupURL.path) else {
                return PetStatsDiskLoadResult(
                    stats: PetStats(),
                    needsRewrite: false,
                    shouldRotateBackup: false,
                    migratedFromSchemaVersion: nil
                )
            }

            // A valid last-known-good backup is useful even when the primary
            // disappeared rather than becoming corrupt. Restore it immediately
            // so a partial external cleanup does not reset earned progress.
            return recoverFromBackup(
                backupURL,
                quarantinedPrimary: nil,
                primaryFailure: nil
            )
        }

        let primaryData: Data
        do {
            primaryData = try Data(contentsOf: url)
        } catch {
            recordIssue(operation: .loadPrimary, at: url, error: error)
            let quarantined = quarantine(url)
            return recoverFromBackup(
                backupURL,
                quarantinedPrimary: quarantined,
                primaryFailure: error
            )
        }

        do {
            let migration = try Self.decodeAndMigrate(primaryData)
            hardenLoadedFile(url)
            return PetStatsDiskLoadResult(
                stats: migration.stats,
                needsRewrite: migration.didMigrate,
                shouldRotateBackup: migration.didMigrate,
                migratedFromSchemaVersion: migration.didMigrate
                    ? migration.originalSchemaVersion
                    : nil
            )
        } catch {
            if let version = newerSchemaVersion(in: error) {
                return readOnlyResult(primaryData, version: version, from: url)
            }
            recordIssue(operation: .loadPrimary, at: url, error: error)
            let quarantined = quarantine(url)
            return recoverFromBackup(
                backupURL,
                quarantinedPrimary: quarantined,
                primaryFailure: error
            )
        }
    }

    private func recoverFromBackup(
        _ backupURL: URL,
        quarantinedPrimary: URL?,
        primaryFailure: Error?
    ) -> PetStatsDiskLoadResult {
        if FileManager.default.fileExists(atPath: backupURL.path) {
            var backupData: Data?
            do {
                let data = try Data(contentsOf: backupURL)
                backupData = data
                let migration = try Self.decodeAndMigrate(data)
                hardenLoadedFile(backupURL)
                recovery = .restoredFromBackup(
                    quarantinedFilename: quarantinedPrimary?.lastPathComponent
                )
                writeDiagnostic(
                    "recovered pet stats from \(backupURL.lastPathComponent)"
                        + quarantineSuffix(quarantinedPrimary)
                )
                return PetStatsDiskLoadResult(
                    stats: migration.stats,
                    needsRewrite: true,
                    shouldRotateBackup: false,
                    migratedFromSchemaVersion: migration.didMigrate
                        ? migration.originalSchemaVersion
                        : nil
                )
            } catch {
                if let backupData, let version = newerSchemaVersion(in: error) {
                    return readOnlyResult(backupData, version: version, from: backupURL)
                }
                recordIssue(operation: .loadBackup, at: backupURL, error: error)
                _ = quarantine(backupURL)
            }
        }

        recovery = .restoredDefaults(
            quarantinedFilename: quarantinedPrimary?.lastPathComponent
        )
        let reason = primaryFailure.map { ": \($0.localizedDescription)" } ?? ""
        writeDiagnostic(
            "restored empty pet stats because no valid primary or backup was available\(reason)"
                + quarantineSuffix(quarantinedPrimary)
        )
        return PetStatsDiskLoadResult(
            stats: PetStats(),
            needsRewrite: true,
            shouldRotateBackup: false,
            migratedFromSchemaVersion: nil
        )
    }

    private func quarantine(_ sourceURL: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return nil }
        let candidate = nextAvailableQuarantineURL(for: sourceURL)

        do {
            try FileManager.default.moveItem(at: sourceURL, to: candidate)
        } catch {
            recordIssue(operation: .quarantine, at: sourceURL, error: error)
            return nil
        }

        do {
            try PrivateFile.hardenFileIfPresent(at: candidate)
        } catch {
            // The bytes are already safely moved aside. Keep returning the
            // quarantine URL, but retain the permission-hardening failure as an
            // observable diagnostic.
            recordIssue(operation: .quarantine, at: candidate, error: error)
        }
        return candidate
    }

    private func hardenLoadedFile(_ fileURL: URL) {
        do {
            try PrivateFile.hardenFileIfPresent(at: fileURL)
        } catch {
            // The decoded stats remain usable. Record the permission failure
            // without misclassifying valid bytes as corruption.
            recordIssue(operation: .harden, at: fileURL, error: error)
        }
    }

    private func nextAvailableQuarantineURL(for sourceURL: URL) -> URL {
        var index = 1
        while true {
            let candidate = URL(fileURLWithPath: sourceURL.path + ".corrupt-\(index)")
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }

    private func quarantineSuffix(_ quarantinedURL: URL?) -> String {
        guard let quarantinedURL else { return "" }
        return "; quarantined unreadable data as \(quarantinedURL.lastPathComponent)"
    }

    // FIX localeCalendarPin: day/week keys and day arithmetic must not shift
    // with the user's region or a non-Gregorian system calendar. A Buddhist
    // system calendar would write "2569-07-02" and a region switch would
    // silently break streaks and quest-day comparisons. Pin en_US_POSIX +
    // Gregorian everywhere; keys produced for an existing Gregorian user are
    // byte-identical, so no migration is needed.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        // YA-30: autoupdating, so a time zone change while the app runs
        // (travel, or the user switching zones) moves the day keys with it
        // instead of keeping the zone captured at launch.
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }()

    private static func dayFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    static func dayString(_ date: Date) -> String {
        dayFormatter().string(from: date)
    }

    static func weekString(_ date: Date) -> String {
        var calendar = Calendar(identifier: .iso8601)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = .autoupdatingCurrent
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return "\(components.yearForWeekOfYear ?? 0)-W\(components.weekOfYear ?? 0)"
    }

    /// Whole days between two yyyy-MM-dd day strings; 0 when either side
    /// is missing or unparseable.
    static func daysBetween(_ start: String, and end: String) -> Int {
        let formatter = dayFormatter()
        guard let startDate = formatter.date(from: start),
              let endDate = formatter.date(from: end) else { return 0 }
        return max(0, calendar.dateComponents([.day], from: startDate, to: endDate).day ?? 0)
    }

    /// YA-30: signed whole days from `start` to `end`. Negative when the
    /// local day moved backwards (travelling west across midnight, or a clock
    /// correction); nil when either side is missing or unparseable.
    static func signedDaysBetween(_ start: String, and end: String) -> Int? {
        let formatter = dayFormatter()
        guard let startDate = formatter.date(from: start),
              let endDate = formatter.date(from: end) else { return nil }
        return calendar.dateComponents([.day], from: startDate, to: endDate).day
    }

    /// Noon on a yyyy-MM-dd day, used as the anchor for day arithmetic when
    /// the effective day differs from the wall clock day.
    static func noon(ofDay day: String) -> Date? {
        guard let start = dayFormatter().date(from: day) else { return nil }
        return calendar.date(byAdding: .hour, value: 12, to: calendar.startOfDay(for: start))
    }

    /// Inclusive journey age in days (start day counts as day 1), or nil when
    /// journeyStartDay is missing or unparseable so the caller can fall back
    /// to the raw streak instead of a bogus one-day cap.
    static func daysSinceJourneyStart(_ start: String, today: String) -> Int? {
        let formatter = dayFormatter()
        guard let startDate = formatter.date(from: start),
              let endDate = formatter.date(from: today) else { return nil }
        let elapsed = calendar.dateComponents([.day], from: startDate, to: endDate).day ?? 0
        return max(0, elapsed) + 1
    }

    /// `gamified` is false while the "Pet and quests" switch is off (YA-31):
    /// the plain counters (today, streak, totals) keep counting, but no quest
    /// completes, no pet earns XP and no event is produced.
    @discardableResult
    func record(words: Int, pet: String = "none", now: Date = Date(), gamified: Bool = true) -> PetStats {
        lastEvents = []
        guard !isReadOnly else { return stats }

        // FIX questStaleRollover: normalize day/week counters before anything
        // reads them, so a dictation on a new day never accumulates onto or
        // completes a quest from yesterday's counts.
        rolloverIfNeeded(now: now)

        // YA-30: count on the effective day, so travelling west across
        // midnight neither resets the streak nor reopens a finished quest.
        let today = stats.effectiveDay(asOf: now)
        let anchor = stats.effectiveAnchor(asOf: now)
        let yesterday = Self.dayString(Self.calendar.date(byAdding: .day, value: -1, to: anchor) ?? anchor)
        let dayBeforeYesterday = Self.dayString(Self.calendar.date(byAdding: .day, value: -2, to: anchor) ?? anchor)
        let currentWeek = Self.weekString(anchor)

        let unlockedBefore = PetKind.allCases.filter { stats.isUnlocked($0) }
        let totalBefore = stats.totalWords
        let petWordsBefore = stats.wordsByPet[pet] ?? 0
        let hatchingBefore = PetKind.allCases.filter { stats.isEggPhase($0) && stats.eggStartWords[$0.rawValue] != nil }

        // Day rollover, streak, and the once-a-week streak saver.
        if stats.lastDictationDay == today {
            stats.wordsToday += words
            stats.dictationsToday += 1
        } else {
            if stats.lastDictationDay == yesterday {
                stats.streakDays += 1
            } else if stats.lastDictationDay == dayBeforeYesterday, stats.streakSaverWeek != currentWeek {
                // Missed exactly one day: the pet covers for you once per week.
                stats.streakDays += 1
                stats.streakSaverWeek = currentWeek
                lastEvents.append(.streakSaved)
            } else {
                stats.streakDays = 1
            }
            stats.wordsToday = words
            stats.dictationsToday = 1
            stats.lastDictationDay = today
        }

        stats.bestStreak = max(stats.bestStreak, stats.streakDays)

        // The journey streak can never exceed the days the journey has
        // existed, so a streak carried in from before the starter choice
        // does not pre-unlock the streak pets.
        if !stats.starter.isEmpty {
            // streak-empty-journeystart-fallback: an empty or unparseable
            // journeyStartDay must not cap the journey streak at 1, which
            // would block the penguin (>= 3) and snail (>= 5) unlocks. Only
            // apply the age cap when we have a real start day to measure from.
            let journeyStreakCap: Int
            if let journeyDays = Self.daysSinceJourneyStart(stats.journeyStartDay, today: today) {
                journeyStreakCap = min(stats.streakDays, journeyDays)
            } else {
                journeyStreakCap = stats.streakDays
            }
            stats.journeyBestStreak = max(stats.journeyBestStreak, journeyStreakCap)
        }

        stats.totalWords += words
        stats.totalDictations += 1

        if stats.weekKey == currentWeek {
            stats.weekWords += words
        } else {
            stats.weekKey = currentWeek
            stats.weekWords = words
        }

        if Self.calendar.component(.hour, from: now) < 10 {
            stats.earlyDay = today
        }

        if gamified {
            checkQuestCompletion(now: now)
        }

        // Completed quest doubles pet XP for the rest of the day.
        // petxp-gated-activepet: never credit XP to a locked pet, even if a
        // raw config rawValue slips through the call site; the gate lives here
        // too so the store is the single source of truth.
        let petKind = PetKind(rawValue: pet)
        let petIsCreditable = gamified && pet != "none" && (petKind.map { stats.isUnlocked($0) } ?? false)
        if petIsCreditable {
            let multiplier = stats.questCompletedDay == today ? 2 : 1
            stats.wordsByPet[pet, default: 0] += words * multiplier
        }

        // Milestones.
        for threshold in PetStats.milestoneThresholds
        where totalBefore < threshold && stats.totalWords >= threshold && !stats.milestonesHit.contains(threshold) {
            stats.milestonesHit.append(threshold)
            lastEvents.append(.milestone(threshold))
        }

        // Level up of the active pet (only pets that actually earned XP).
        // YA-65: an egg does not level up out loud. XP still banks while it
        // hatches; the hatch event announces it instead.
        if petIsCreditable, let petKind, !hatchingBefore.contains(petKind), !stats.isEggPhase(petKind) {
            let before = petLevel(forWords: petWordsBefore)
            let after = petLevel(forWords: stats.wordsByPet[pet] ?? 0)
            if after > before {
                lastEvents.append(.levelUp(after))
            }
        }

        appendUnlockEvents(unlockedBefore: unlockedBefore)

        // Eggs that just hatched.
        for kind in hatchingBefore where !stats.isEggPhase(kind) {
            lastEvents.append(.hatched(kind))
        }

        if !gamified {
            // Milestones above are still marked as hit so they never fire
            // late when the switch is turned back on; nothing is announced.
            lastEvents = []
        }

        save()
        return stats
    }

    /// Newly unlocked pets since `unlockedBefore` was taken.
    private func appendUnlockEvents(unlockedBefore: [PetKind]) {
        for kind in PetKind.allCases
        where kind.requiresUnlock && !unlockedBefore.contains(kind) && stats.isUnlocked(kind) {
            lastEvents.append(.unlocked(kind))
        }
    }

    /// Starts the hatch counter the first time an unlockable pet is selected.
    func markEggStart(pet: String) {
        guard !isReadOnly, let kind = PetKind(rawValue: pet),
              kind != .none,
              stats.isUnlocked(kind),
              stats.eggStartWords[pet] == nil else {
            return
        }

        stats.eggStartWords[pet] = stats.totalWords
        save()
    }

    /// One-time starter choice; the journey begins with the starter's egg
    /// and every unlock counter starts from this moment.
    func chooseStarter(_ kind: PetKind, now: Date = Date()) {
        guard !isReadOnly, stats.starter.isEmpty, PetKind.starters.contains(kind) else { return }
        stats.starter = kind.rawValue
        stats.beginJourney(day: Self.dayString(now))
        stats.eggStartWords = [kind.rawValue: stats.totalWords]
        save()
    }

    /// Per-pet wardrobe: each pet owns what it earned.
    func setAccessory(_ accessory: PetAccessory, for pet: PetKind) {
        guard !isReadOnly, pet != .none else { return }
        guard petLevel(forWords: stats.words(for: pet)) >= accessory.unlockLevel else { return }
        stats.accessoriesByPet[pet.rawValue] = accessory.rawValue
        save()
    }

    /// Zeroes the day- and week-scoped counters once the calendar has moved
    /// past the day/week they were recorded in. Streak state (lastDictationDay,
    /// streakDays) is deliberately left alone — record() owns streak
    /// continuation. Every mutating entry point that can trigger a quest check
    /// calls this first, so a quest is never accumulated onto or completed from
    /// yesterday's counters.
    /// FIX questStaleRollover
    func rolloverIfNeeded(now: Date = Date()) {
        let today = stats.effectiveDay(asOf: now)
        if stats.lastDictationDay != today, stats.wordsToday != 0 || stats.dictationsToday != 0 {
            stats.wordsToday = 0
            stats.dictationsToday = 0
        }
        let currentWeek = Self.weekString(stats.effectiveAnchor(asOf: now))
        if stats.weekKey != currentWeek, stats.weekWords != 0 {
            stats.weekWords = 0
        }
    }

    /// Records that a glossary word was saved today (feeds the teach quest).
    @discardableResult
    func markGlossaryTaught(now: Date = Date(), gamified: Bool = true) -> [PetEvent] {
        lastEvents = []
        guard gamified, !isReadOnly else { return lastEvents }
        // FIX questStaleRollover: without this, teaching a word on a fresh day
        // ran checkQuestCompletion against yesterday's un-rolled wordsToday and
        // could auto-complete today's quest with zero dictations.
        rolloverIfNeeded(now: now)
        let unlockedBefore = PetKind.allCases.filter { stats.isUnlocked($0) }
        stats.glossaryTaughtDay = stats.effectiveDay(asOf: now)
        checkQuestCompletion(now: now)
        // YA-64: a quest finished here can unlock the frog or the otter.
        appendUnlockEvents(unlockedBefore: unlockedBefore)
        save()
        return lastEvents
    }

    private func checkQuestCompletion(now: Date) {
        let today = stats.effectiveDay(asOf: now)
        guard stats.questCompletedDay != today else { return }
        // YA-30: a quest finished on a later day already (clock moved back)
        // never lets an earlier day's quest count a second time.
        if let gap = Self.signedDaysBetween(stats.questCompletedDay, and: today), gap < 0 { return }

        let quest = DailyQuest.forDay(today)
        if quest.progress(in: stats, day: today) >= quest.target {
            stats.questCompletedDay = today
            stats.questsCompletedTotal += 1
            lastEvents.append(.questCompleted)
        }
    }

    private func save(rotatingBackup: Bool = true) {
        // YA-66: never overwrite a newer schema with this older one.
        guard !isReadOnly else { return }
        do {
            let data = try Self.encodedCurrentStats(stats)
            if rotatingBackup {
                rotatePrimaryIntoBackupIfValid()
            }
            try PrivateFile.write(data, to: url)
            stats.schemaVersion = PetStats.currentSchemaVersion
        } catch {
            recordIssue(operation: .save, at: url, error: error)
        }
    }

    /// Copy the currently valid primary bytes to the last-known-good backup
    /// before replacing them. Never promote unreadable bytes to the backup.
    private func rotatePrimaryIntoBackupIfValid() {
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        let previousData: Data
        do {
            previousData = try Data(contentsOf: url)
            _ = try Self.decodeAndMigrate(previousData)
        } catch {
            recordIssue(operation: .backup, at: url, error: error)
            _ = quarantine(url)
            return
        }

        do {
            try PrivateFile.write(previousData, to: Self.backupURL(for: url))
        } catch {
            // Keep saving the new atomic primary: a backup failure should not
            // discard the newest in-memory progress. The previous primary is
            // still intact until PrivateFile's atomic replacement succeeds.
            recordIssue(operation: .backup, at: Self.backupURL(for: url), error: error)
        }
    }

    private func recordIssue(
        operation: PetStatsPersistenceOperation,
        at fileURL: URL,
        error: Error
    ) {
        let issue = PetStatsPersistenceIssue(
            operation: operation,
            filename: fileURL.lastPathComponent,
            message: error.localizedDescription
        )
        persistenceIssues.append(issue)
        writeDiagnostic("\(operation.rawValue) failed for \(issue.filename): \(issue.message)")
    }

    private func writeDiagnostic(_ message: String) {
        FileHandle.standardError.write(Data("YappYapp non-fatal: \(message)\n".utf8))
    }

}
