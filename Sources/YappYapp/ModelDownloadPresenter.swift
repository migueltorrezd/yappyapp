import Foundation

struct AppNotificationCopy: Equatable {
    let title: String
    let body: String
}

enum ModelDownloadPresenter {
    /// Downloads are off. Only a user who can change that is sent to Setup;
    /// a managed Mac that locks the switch is sent to the IT admin.
    static func downloadsOffStatus(lockedByAdmin: Bool) -> String {
        lockedByAdmin
            ? L10n.tr("Downloads are off on this Mac. Ask your IT admin.")
            : L10n.tr("Downloads are off. Turn them on in Setup.")
    }
    static var canceledStatus: String { L10n.tr("Download canceled.") }

    /// Shown beside the indeterminate spinner while a Parakeet model is
    /// compiling/loading CoreML locally (the second half of the fetch, which
    /// is CPU-bound rather than network and has no smooth byte progress).
    static var preparingStatus: String { L10n.tr("Preparing\u{2026}") }

    // YA-75: "stays active meanwhile" is only true when the selected model is
    // actually installed. On a first download nothing is active yet.
    static func startedStatus(optionName: String, selectedModelName: String, selectedModelInstalled: Bool = true) -> String {
        guard selectedModelInstalled else {
            return L10n.tr("Downloading %@\u{2026} You can dictate the moment it's done.", optionName)
        }
        return L10n.tr("Downloading %@\u{2026} Keep dictating with %@ meanwhile.", optionName, selectedModelName)
    }

    static func managerFailedNotification(errorDescription: String) -> AppNotificationCopy {
        AppNotificationCopy(title: L10n.tr("Download failed"), body: errorDescription)
    }

    static func parakeetFailedNotification(optionName: String, errorDescription: String) -> AppNotificationCopy {
        AppNotificationCopy(title: L10n.tr("Download failed"), body: "\(optionName): \(errorDescription)")
    }

    static func readyNotification(optionName: String) -> AppNotificationCopy {
        AppNotificationCopy(
            title: L10n.tr("%@ is ready.", optionName),
            body: L10n.tr("Downloaded. Switching to it now.")
        )
    }
}

/// One chip vocabulary for a Models row: DOWNLOAD, DOWNLOADING %,
/// PREPARING, DOWNLOADED, IN USE, FAILED (with RETRY), DOWNLOADS OFF.
enum ModelRowChip: Equatable {
    case download
    case downloading(percent: Int)
    case preparing
    case downloaded
    case inUse
    case failed
    case downloadsOff

    static func state(
        isInstalled: Bool,
        isSelected: Bool,
        downloadProgress: Double?,
        downloadError: String?,
        downloadsAllowed: Bool
    ) -> ModelRowChip {
        if let downloadProgress {
            return downloadProgress < 0 ? .preparing : .downloading(percent: Int(downloadProgress * 100))
        }
        if isInstalled { return isSelected ? .inUse : .downloaded }
        if !downloadsAllowed { return .downloadsOff }
        if downloadError != nil { return .failed }
        return .download
    }

    var text: String {
        switch self {
        case .download: L10n.tr("DOWNLOAD")
        case .downloading(let percent): "\(percent)%"
        case .preparing: ModelDownloadPresenter.preparingStatus.uppercased()
        case .downloaded: L10n.tr("DOWNLOADED")
        case .inUse: L10n.tr("IN USE")
        case .failed: L10n.tr("FAILED")
        case .downloadsOff: L10n.tr("Downloads off").uppercased()
        }
    }
}

/// What the Models list shows: the recommended tag and whether the Whisper
/// family starts open.
/// The model families on MODELS, each behind the same one-line header.
enum ModelGroup: Equatable {
    case parakeet
    case whisper
    case qwen3asr
    case translation

    func title(count: Int) -> String {
        switch self {
        case .parakeet: L10n.tr("PARAKEET (%@)", "\(count)")
        case .whisper: L10n.tr("WHISPER (%@)", "\(count)")
        case .qwen3asr: L10n.tr("QWEN3-ASR (%@)", "\(count)")
        case .translation: L10n.tr("TRANSLATION (%@)", "\(count)")
        }
    }

    var detail: String {
        switch self {
        case .parakeet: L10n.tr("FAST AND ACCURATE · START HERE")
        // One line in every language and text size: translation is described
        // by its own family, not by Whisper's.
        case .whisper: L10n.tr("MORE LANGUAGES")
        case .qwen3asr: L10n.tr("52 LANGUAGES")
        case .translation: L10n.tr("10 LANGUAGES · ON THIS MAC")
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .parakeet: L10n.tr("Parakeet models")
        case .whisper: L10n.tr("Whisper models")
        case .qwen3asr: L10n.tr("Qwen3-ASR models")
        case .translation: L10n.tr("Translation models")
        }
    }

    var showHint: String {
        switch self {
        case .parakeet: L10n.tr("Shows the Parakeet models")
        case .whisper: L10n.tr("Shows the Whisper models")
        case .qwen3asr: L10n.tr("Shows the Qwen3-ASR models")
        case .translation: L10n.tr("Shows the translation models")
        }
    }

    var hideHint: String {
        switch self {
        case .parakeet: L10n.tr("Hides the Parakeet models")
        case .whisper: L10n.tr("Hides the Whisper models")
        case .qwen3asr: L10n.tr("Hides the Qwen3-ASR models")
        case .translation: L10n.tr("Hides the translation models")
        }
    }
}

/// Open or closed for a model family header. The user's last click wins;
/// until then the family's default applies.
enum ModelGroupDisclosure {
    static func isOpen(userChoice: Bool?, opensByDefault: Bool) -> Bool {
        userChoice ?? opensByDefault
    }

    static func chevron(isOpen: Bool) -> String {
        isOpen ? "\u{25B2}" : "\u{25BC}"
    }
}

/// QWEN3-ASR: when a speech model row offers DELETE.
enum ModelRowDelete {
    /// Downloaded, not the model in use, and not mid-download.
    static func isOffered(isInstalled: Bool, isSelected: Bool, downloadProgress: Double?) -> Bool {
        isInstalled && !isSelected && downloadProgress == nil
    }
}

enum ModelListPolicy {
    /// Parakeet is where most people start, so its family starts open.
    static let parakeetOpensByDefault = true

    static func isRecommended(_ option: ModelOption) -> Bool {
        option.id == ModelCatalog.recommendedID
    }

    /// Whisper starts closed unless one of its models is in use,
    /// downloading or showing a failure, so that row is never hidden.
    static func whisperOpensByDefault(
        selectedID: String,
        downloads: [String: Double],
        errors: [String: String]
    ) -> Bool {
        ModelCatalog.options.contains { option in
            option.engine == .whisper
                && (option.id == selectedID || downloads[option.id] != nil || errors[option.id] != nil)
        }
    }

    /// QWEN3-ASR starts closed like Whisper, with the same exceptions.
    static func qwen3ASROpensByDefault(
        selectedID: String,
        downloads: [String: Double],
        errors: [String: String]
    ) -> Bool {
        ModelCatalog.options.contains { option in
            option.engine == .qwen3asr
                && (option.id == selectedID || downloads[option.id] != nil || errors[option.id] != nil)
        }
    }

    /// Translation starts closed unless translation is on or one of its
    /// models is downloading or failed.
    static func translationOpensByDefault(target: TranslationTarget, snapshot: TranslationModelsSnapshot) -> Bool {
        target != .off || snapshot.phases.values.contains { $0 != .idle }
    }
}
