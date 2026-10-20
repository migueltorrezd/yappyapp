import SwiftUI

/// PROFILES (missing feature 9): SETUP > APP PROFILES. Add an app you
/// dictate into, then pick what changes there. Nothing is created for you.
struct AppProfilesSettingsSection: View {
    @Binding var profiles: [AppProfile]
    let lockedKeys: Set<ManagedConfigKey>
    /// Installed models a profile can switch to.
    let modelChoices: [ModelOption]
    let cleanupModelInstalled: Bool
    /// Called only when the picker opens, so rendering never lists apps.
    let candidateProvider: () -> [ProfileAppCandidate]

    @State private var candidates: [ProfileAppCandidate] = []
    @State private var expandedID: UUID?

    init(
        profiles: Binding<[AppProfile]>,
        lockedKeys: Set<ManagedConfigKey>,
        modelChoices: [ModelOption],
        cleanupModelInstalled: Bool,
        candidateProvider: @escaping () -> [ProfileAppCandidate],
        initiallyExpanded: UUID? = nil
    ) {
        _profiles = profiles
        self.lockedKeys = lockedKeys
        self.modelChoices = modelChoices
        self.cleanupModelInstalled = cleanupModelInstalled
        self.candidateProvider = candidateProvider
        _expandedID = State(initialValue: initiallyExpanded)
    }

    /// The rows of SETUP > APP PROFILES. The section card around them
    /// belongs to the Setup tab.
    var body: some View {
        VStack(alignment: .leading, spacing: BrutalControl.rowSpacing) {
            // The intro and the empty state read as one note.
            VStack(alignment: .leading, spacing: BrutalControl.innerSpacing) {
                BrutalCaption(AppProfileCopy.intro)
                if profiles.isEmpty {
                    BrutalCaption(AppProfileCopy.empty)
                }
            }

            ForEach(profiles) { profile in
                profileCard(profile)
            }

            addBlock
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Profile card

    private func binding(for id: UUID) -> Binding<AppProfile>? {
        guard profiles.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { profiles.first { $0.id == id } ?? AppProfile(bundleID: "", appName: "") },
            set: { newValue in
                if let index = profiles.firstIndex(where: { $0.id == id }) {
                    profiles[index] = newValue
                }
            }
        )
    }

    @ViewBuilder
    private func profileCard(_ profile: AppProfile) -> some View {
        let expanded = expandedID == profile.id
        VStack(alignment: .leading, spacing: BrutalControl.rowSpacing) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: BrutalControl.lineSpacing) {
                    Text(profile.appName)
                        .brutalText(.rowLabel)
                        .foregroundStyle(Brutal.ink)
                        .lineLimit(1)
                    Text(AppProfileCopy.summary(profile, modelChoices: modelChoices))
                        .brutalText(.caption)
                        .foregroundStyle(Brutal.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                BrutalActionButton(
                    title: expanded ? L10n.tr("DONE") : L10n.tr("EDIT"),
                    accessibilityLabel: expanded ? L10n.tr("Close %@ profile", profile.appName) : L10n.tr("Edit %@ profile", profile.appName),
                    hint: L10n.tr("Shows what changes when you dictate into %@", profile.appName)
                ) {
                    expandedID = expanded ? nil : profile.id
                }
                BrutalActionButton(
                    title: L10n.tr("REMOVE"),
                    accessibilityLabel: L10n.tr("Remove %@ profile", profile.appName),
                    hint: L10n.tr("%@ goes back to your Setup choices", profile.appName)
                ) {
                    profiles.removeAll { $0.id == profile.id }
                    if expandedID == profile.id { expandedID = nil }
                }
            }

            if expanded, let binding = binding(for: profile.id) {
                editor(binding)
            }
        }
        .padding(10)
        .background(Brutal.paper)
        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(L10n.tr("%@ profile", profile.appName)))
    }

    @ViewBuilder
    private func editor(_ profile: Binding<AppProfile>) -> some View {
        let appName = profile.wrappedValue.appName
        VStack(alignment: .leading, spacing: BrutalControl.rowSpacing) {
            optionRow(L10n.tr("DICTATION LANGUAGE"), options: LanguageCatalog.options.map { ($0.code, $0.brutalLabel) },
                      value: profile.language, appName: appName)
                .managedLock(lockedKeys.contains(.language), placement: .below)

            VStack(alignment: .leading, spacing: BrutalControl.innerSpacing) {
                optionRow(L10n.tr("CLEANUP"), options: ProfileCleanupMode.offered.map { ($0.rawValue, $0.label) },
                          value: profile.cleanupMode, appName: appName)
                if AppProfileCopy.needsCleanupModel(profile.wrappedValue, installed: cleanupModelInstalled) {
                    BrutalCaption(AppProfileCopy.cleanupModelMissing)
                }
            }

            // Three short options fit one line, so PASTE is segmented.
            VStack(alignment: .leading, spacing: BrutalControl.innerSpacing) {
                BrutalRowLabel(L10n.tr("PASTE"))
                BrutalSegmented(
                    choices: [sameAsSetup(L10n.tr("PASTE"), appName: appName)] + ProfilePasteBehavior.allCases.map { behavior in
                        BrutalChoice<String?>(
                            value: behavior.rawValue,
                            title: behavior.label,
                            accessibilityLabel: "\(L10n.tr("PASTE").capitalized) \(behavior.label.lowercased())",
                            hint: L10n.tr("Uses this in %@ only", appName)
                        )
                    },
                    selection: profile.wrappedValue.pasteBehavior?.rawValue,
                    hint: L10n.tr("Uses this in %@ only", appName)
                ) { profile.wrappedValue.pasteBehavior = $0.flatMap(ProfilePasteBehavior.init(rawValue:)) }
            }
            .managedLock(lockedKeys.contains(.autoPaste), placement: .below)

            modelRow(profile)
                .managedLock(lockedKeys.contains(.selectedModel), placement: .below)

            // NUMBERS: e.g. DIGITS for a terminal.
            optionRow(L10n.tr("NUMBERS"), options: NumberStyle.allCases.map { ($0.rawValue, $0.label) },
                      value: profile.numberStyle, appName: appName)
                .managedLock(lockedKeys.contains(.numberStyle), placement: .below)
        }
    }

    private func sameAsSetup(_ title: String, appName: String) -> BrutalChoice<String?> {
        BrutalChoice(
            value: nil,
            title: L10n.tr("SAME AS SETUP"),
            accessibilityLabel: L10n.tr("%@ same as Setup", title.capitalized),
            hint: L10n.tr("Uses the Setup value in %@", appName)
        )
    }

    /// Pick one of many per app: SAME AS SETUP, then every option.
    private func optionRow(
        _ title: String,
        options: [(value: String, label: String)],
        value: Binding<String?>,
        appName: String
    ) -> some View {
        VStack(alignment: .leading, spacing: BrutalControl.innerSpacing) {
            BrutalRowLabel(title)
            BrutalPicker(
                choices: [sameAsSetup(title, appName: appName)] + options.map { option in
                    BrutalChoice<String?>(
                        value: option.value,
                        title: option.label,
                        accessibilityLabel: "\(title.capitalized) \(option.label.lowercased())",
                        hint: L10n.tr("Uses this in %@ only", appName)
                    )
                },
                selection: value.wrappedValue,
                accessibilityLabel: title.capitalized,
                hint: L10n.tr("Uses this in %@ only", appName)
            ) { value.wrappedValue = $0 }
        }
    }

    private func modelRow(_ profile: Binding<AppProfile>) -> some View {
        let current = profile.wrappedValue.modelPath
        let appName = profile.wrappedValue.appName
        let missing = current.map { path in !modelChoices.contains { $0.defaultPath == path } } ?? false
        return VStack(alignment: .leading, spacing: BrutalControl.innerSpacing) {
            BrutalRowLabel(L10n.tr("MODEL"))
            BrutalPicker(
                choices: [
                    BrutalChoice<String?>(
                        value: nil,
                        title: L10n.tr("SAME AS SETUP"),
                        accessibilityLabel: L10n.tr("Model same as Setup"),
                        hint: L10n.tr("Uses the Setup model in %@", appName)
                    )
                ] + modelChoices.map { option in
                    BrutalChoice<String?>(
                        value: option.defaultPath,
                        title: option.name,
                        accessibilityLabel: L10n.tr("Model %@", option.name),
                        hint: L10n.tr("Uses this model in %@ only", appName)
                    )
                },
                selection: current,
                accessibilityLabel: L10n.tr("MODEL").capitalized,
                hint: L10n.tr("Uses this model in %@ only", appName)
            ) { profile.wrappedValue.modelPath = $0 }
            if missing {
                BrutalCaption(AppProfileCopy.modelMissing)
            } else if current != nil {
                BrutalCaption(AppProfileCopy.modelSwitchCost)
            }
        }
    }

    // MARK: - Add

    private var addBlock: some View {
        BrutalDropdown(
            title: L10n.tr("ADD APP"),
            accessibilityLabel: L10n.tr("Add app"),
            hint: L10n.tr("Apps you dictated into, plus open apps"),
            leadingSymbol: "plus",
            emptyText: AppProfileCopy.noCandidates,
            onOpen: { candidates = candidateProvider() }
        ) {
            candidates.map { candidate in
                BrutalMenuItem(
                    id: candidate.bundleID,
                    title: candidate.name,
                    leadingSymbol: "plus",
                    accessibilityLabel: L10n.tr("Add %@", candidate.name),
                    hint: L10n.tr("Adds %@. It stays the same as Setup until you change something.", candidate.name)
                ) {
                    let profile = AppProfile(bundleID: candidate.bundleID, appName: candidate.name)
                    profiles = AppProfileList.deduplicated(profiles + [profile])
                    expandedID = profile.id
                }
            }
        }
    }
}

/// Left-to-right chips that wrap onto the next line instead of overflowing
/// the fixed-width popover.
struct BrutalChipFlow: Layout {
    var spacing: CGFloat = 4

    init(spacing: CGFloat = 4) {
        self.spacing = spacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}

enum AppProfileCopy {
    static var intro: String { L10n.tr("Give one app its own language, cleanup, paste, model or numbers. Every other app keeps the settings above.") }
    static var empty: String { L10n.tr("No profiles yet. Add an app below.") }
    static var noCandidates: String { L10n.tr("No other apps open. Open one, then try again.") }
    static var modelMissing: String { L10n.tr("That model isn't downloaded. Your main model runs instead.") }
    static var modelSwitchCost: String { L10n.tr("Another model loads first, so the first dictation is slower.") }
    static var cleanupModelMissing: String { L10n.tr("This mode needs the cleanup model. Pick Clean in Setup > Dictation to download it.") }

    static func needsCleanupModel(_ profile: AppProfile, installed: Bool) -> Bool {
        !installed && AppProfileResolver.cleanupEnabled(for: profile.cleanupMode) == true
    }

    /// One line under the app name: what this profile changes.
    static func summary(_ profile: AppProfile, modelChoices: [ModelOption]) -> String {
        guard !profile.followsSetup else { return L10n.tr("SAME AS SETUP") }
        var parts: [String] = []
        if let language = profile.language {
            parts.append(LanguageCatalog.options.first { $0.code == language }?.brutalLabel ?? language.uppercased())
        }
        if let mode = profile.cleanupMode {
            parts.append(ProfileCleanupMode(rawValue: mode)?.label ?? mode.uppercased())
        }
        if let paste = profile.pasteBehavior {
            parts.append(paste.label)
        }
        if let modelPath = profile.modelPath {
            parts.append(DictationBadge.modelLabel(for: modelPath))
        }
        if let style = profile.numberStyle {
            parts.append(NumberStyle(rawValue: style).map { L10n.tr("NUMBERS %@", $0.label) } ?? style.uppercased())
        }
        return parts.joined(separator: " · ")
    }
}
