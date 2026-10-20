import Foundation

struct ParakeetCacheSnapshot: Equatable {
    let selectedModelID: String
    let selectedModelName: String
    let variant: String
    let cachePath: String
    let isCached: Bool
}

enum ModelDiagnostics {
    static let parakeetCacheStatusOverrideKey = "YAPPYAPP_PARAKEET_CACHE_STATUS_OVERRIDE"

    static func parakeetCacheSnapshot(
        for modelPath: String,
        forcedCacheStatus: Bool? = nil,
        cachePath: (String) -> String = parakeetCacheDirectoryPath,
        isCached: (String) -> Bool = parakeetModelDownloaded
    ) -> ParakeetCacheSnapshot? {
        guard ModelCatalog.engine(for: modelPath) == .parakeet else { return nil }

        let selectedID = ModelCatalog.selectedID(for: modelPath)
        let option = ModelCatalog.option(for: selectedID)
        let variant = option?.parakeetVariant ?? "v3"

        return ParakeetCacheSnapshot(
            selectedModelID: selectedID,
            selectedModelName: option?.name ?? "Parakeet",
            variant: variant,
            cachePath: cachePath(variant),
            isCached: forcedCacheStatus ?? isCached(variant)
        )
    }

    static func parakeetCacheStatusOverride(from environment: [String: String]) -> Bool? {
        guard let rawValue = environment[parakeetCacheStatusOverrideKey] else { return nil }

        switch rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "installed":
            return true
        case "missing":
            return false
        default:
            return nil
        }
    }

    static func printParakeetCacheStatus(for modelPath: String?) -> Never {
        guard let modelPath, !modelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("model.engine=unknown")
            print("model.cache=unknown")
            exit(1)
        }

        let forcedCacheStatus = parakeetCacheStatusOverride(from: ProcessInfo.processInfo.environment)

        guard let snapshot = parakeetCacheSnapshot(for: modelPath, forcedCacheStatus: forcedCacheStatus) else {
            print("model.engine=whisper")
            print("model.cache=not-applicable")
            exit(0)
        }

        print("model.engine=parakeet")
        print("model.id=\(snapshot.selectedModelID)")
        print("model.name=\(snapshot.selectedModelName)")
        print("model.variant=\(snapshot.variant)")
        print("model.cache.path=\(snapshot.cachePath)")
        print("model.cache=\(snapshot.isCached ? "installed" : "missing")")
        if forcedCacheStatus != nil {
            print("model.cache.source=diagnostic-override")
        }
        exit(0)
    }
}
