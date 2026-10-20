import SwiftUI

extension BrutalistPopoverView {
    // MARK: - Pet

    private var currentPetKind: PetKind {
        state.activePet
    }

    private func selectPet(_ kind: PetKind) {
        // FIX draftSaveRace: build from the live draft, not state.config, and
        // cancel the pending autosave. Otherwise a toggle changed inside the
        // 700ms debounce is lost — this save carried state.config's old value,
        // and onChange(of: state.config) then reset the draft over the edit,
        // or the pending autosave later re-saved the pre-pet draft.
        autosaveTask?.cancel()
        var config = configDraft
        config.pet = kind.rawValue
        onSaveConfig(config)
    }

    var petTab: some View {
        Group {
            // MANAGED-PREFS: a profile that turns the pet off locks this tab.
            if state.managedConfigKeys.contains(.petEnabled) {
                ManagedPetLockedView()
            } else if !state.config.petEnabled {
                petOffNotice
            } else if state.petStats.starter.isEmpty {
                starterChooser
            } else {
                petTabContent
            }
        }
    }

    private var starterChooser: some View {
        VStack(spacing: 14) {
            Spacer()

            Text(L10n.tr("CHOOSE YOUR FIRST PET"))
                .brutalFont(size: 16, weight: .black, relativeTo: .headline)
                .kerning(1.5)
                .foregroundStyle(Brutal.ink)

            Text(L10n.tr("IT'S DANGEROUS TO GO ALONE, TAKE THIS."))
                .brutalFont(size: 9, weight: .black, relativeTo: .caption)
                .kerning(0.6)
                .foregroundStyle(Brutal.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            HStack(spacing: 12) {
                ForEach(PetKind.starters) { kind in
                    Button {
                        onChooseStarter(kind)
                    } label: {
                        VStack(spacing: 9) {
                            AnimatedPetPreview(kind: kind, pixel: 3.4)
                                .frame(height: 52)

                            Text(kind.label.uppercased())
                                .brutalFont(size: 11, weight: .black, relativeTo: .callout)
                                .kerning(0.8)
                                .foregroundStyle(Brutal.ink)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(BrutalButtonStyle(fill: Brutal.card))
                    .brutalInteractive(
                        label: L10n.tr("Choose %@", kind.label),
                        hint: L10n.tr("Chooses %@ as your first pet", kind.label),
                        hitExpansion: 0
                    )
                }
            }
            .padding(.trailing, Brutal.drop)

            Spacer()
        }
    }

    private var petTabContent: some View {
        BrutalScroll {
            VStack(spacing: 12) {
                if PetDebugAccess.isEnabled {
                    Text(L10n.tr("DEBUG UNLOCKS ON · PROGRESSION FILE UNCHANGED"))
                        .brutalFont(size: 8.5, weight: .black, relativeTo: .caption2)
                        .kerning(0.6)
                        .foregroundStyle(Brutal.contentOnYellow)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Brutal.yellow)
                        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
                }

                // YA-66: stats from a newer YappYapp are shown, never rewritten.
                if state.petStats.schemaVersion > PetStats.currentSchemaVersion {
                    Text(L10n.tr("SAVED BY A NEWER YAPPYAPP · UPDATE TO KEEP COUNTING"))
                        .brutalFont(size: 8.5, weight: .black, relativeTo: .caption2)
                        .kerning(0.6)
                        .foregroundStyle(Brutal.contentOnYellow)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Brutal.yellow)
                        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
                }

                VStack(spacing: 0) {
                    Text(L10n.tr("YOUR PET"))
                        .brutalFont(size: 9, weight: .black, relativeTo: .caption)
                        .kerning(1.2)
                        .foregroundStyle(Brutal.paper)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(Brutal.ink)

                    VStack(spacing: 7) {
                        if currentPetKind == .none {
                            Text(L10n.tr("NO PET. JUST WORK."))
                                .brutalFont(size: 12, weight: .black, relativeTo: .callout)
                                .kerning(0.8)
                                .foregroundStyle(Brutal.textSecondary)
                                .frame(height: 70)
                        } else if state.petStats.isEggPhase(currentPetKind) {
                            PetThumb(kind: currentPetKind, pixel: 5, asEgg: true)
                                .frame(height: 70)

                            Text(L10n.tr("HATCHING: %@/%@ WORDS", "\(state.petStats.hatchProgress(currentPetKind))", "\(PetStats.hatchTarget)"))
                                .brutalFont(size: 9, weight: .black, design: .monospaced, relativeTo: .caption)
                                .foregroundStyle(Brutal.dangerText)
                        } else {
                            AnimatedPetPreview(
                                kind: currentPetKind,
                                pixel: 5,
                                accessory: state.petStats.accessory(for: currentPetKind)
                            )
                            .frame(height: 70)

                            Text(currentPetKind.label.uppercased())
                                .brutalFont(size: 13, weight: .black, relativeTo: .headline)
                                .kerning(1)
                                .foregroundStyle(Brutal.ink)

                            Text(L10n.tr("LVL %@ · %@ WORDS TOGETHER", "\(petLevel(forWords: state.petStats.words(for: currentPetKind)))", "\(state.petStats.words(for: currentPetKind))"))
                                .brutalFont(size: 9, weight: .black, design: .monospaced, relativeTo: .caption)
                                .foregroundStyle(Brutal.blue)
                        }
                    }
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(Brutal.card)
                }
                .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
                .background(Rectangle().fill(Brutal.ink).offset(x: Brutal.drop, y: Brutal.drop))

                brutalQuestBlock

                HStack(spacing: 10) {
                    // FIX staleDayDisplay: normalized reads so a new day is 0
                    // and a broken streak reads 0, not yesterday's numbers.
                    brutalStatBlock(L10n.tr("TODAY"), "\(state.petStats.wordsTodayDisplayed())")
                    brutalStatBlock(L10n.tr("STREAK"), L10n.plural("%lld DAYS", state.petStats.streakDisplayed()))
                    brutalStatBlock(L10n.tr("TOTAL"), "\(state.petStats.totalWords)")
                }

                // MARKER privacyAndTimeSaved: time-saved stat
                brutalStatBlock(L10n.tr("TIME SAVED TYPING"), TimeSavedMath.shortLabel(words: state.petStats.totalWords))

                brutalWardrobeRow

                if state.petStats.streakSaverWeek == PetStatsStore.weekString(state.petStats.effectiveAnchor()) {
                    Text(L10n.tr("YOUR PET COVERED A MISSED DAY. STREAK SAVED."))
                        .brutalFont(size: 9, weight: .black, relativeTo: .caption)
                        .kerning(0.6)
                        .foregroundStyle(Brutal.contentOnGreen)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Brutal.green)
                        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: 1.5))
                }

                VStack(spacing: 8) {
                    ForEach(PetKind.allCases) { kind in
                        brutalPetRow(kind)
                    }
                }

                Button(L10n.tr("SAVE RECAP CARD")) {
                    onSaveRecap()
                }
                .buttonStyle(BrutalTextButtonStyle(fill: Brutal.blue, text: Brutal.paper))
                .help(L10n.tr("Saves a shareable weekly stats card to Pictures/YappYapp"))
                .brutalInteractive(
                    label: L10n.tr("Save recap card"),
                    hint: L10n.tr("Saves a shareable weekly stats card to Pictures/YappYapp"),
                    hitExpansion: 5
                )
            }
            .padding(.bottom, Brutal.drop)
            .padding(.trailing, Brutal.drop)
        }
        .scrollIndicators(.never)
    }

    private var brutalQuestBlock: some View {
        // YA-30: the same effective day the store counts on.
        let today = state.petStats.effectiveDay()
        let quest = DailyQuest.forDay(today)
        let progress = quest.progress(in: state.petStats, day: today)
        let done = state.petStats.questCompletedDay == today

        return HStack(spacing: 9) {
            Text(done ? "✓" : "!")
                .brutalFont(size: 13, weight: .black, relativeTo: .headline)
                .foregroundStyle(done ? Brutal.contentOnGreen : Brutal.contentOnYellow)
                .frame(width: 22, height: 22)
                .background(done ? Brutal.green : Brutal.yellow)
                .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: 1.5))

            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.tr("DAILY QUEST"))
                    .brutalFont(size: 7.5, weight: .black, relativeTo: .caption2)
                    .kerning(0.9)
                    .foregroundStyle(Brutal.textTertiary)

                Text(quest.title.uppercased())
                    .brutalFont(size: 10, weight: .black, relativeTo: .caption)
                    .kerning(0.5)
                    .foregroundStyle(Brutal.ink)
            }

            Spacer()

            Text(done ? L10n.tr("DONE · 2X XP") : "\(progress)/\(quest.target)")
                .brutalFont(size: 10, weight: .black, design: .monospaced, relativeTo: .caption)
                .foregroundStyle(done ? Brutal.successText : Brutal.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Brutal.card)
        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
        .background(Rectangle().fill(Brutal.ink).offset(x: Brutal.drop, y: Brutal.drop))
    }

    private var brutalWardrobeRow: some View {
        let level = petLevel(forWords: state.petStats.words(for: currentPetKind))

        return HStack(spacing: 6) {
            Text(L10n.tr("WARDROBE"))
                .brutalFont(size: 8.5, weight: .black, relativeTo: .caption2)
                .kerning(0.8)
                .foregroundStyle(Brutal.textTertiary)

            ForEach(PetAccessory.allCases) { accessory in
                let unlocked = level >= accessory.unlockLevel
                let selected = state.petStats.accessory(for: currentPetKind) == accessory

                Button {
                    guard unlocked else { return }
                    onEquipAccessory(accessory)
                } label: {
                    Text(unlocked ? accessory.label.uppercased() : L10n.tr("LVL %@", "\(accessory.unlockLevel)"))
                        .brutalFont(size: 8.5, weight: .black, relativeTo: .caption2)
                        .kerning(0.5)
                        .padding(.horizontal, 7)
                        .frame(minHeight: 22)
                        .background(selected ? Brutal.ink : Brutal.card)
                        .foregroundStyle(selected ? Brutal.paper : (unlocked ? Brutal.textPrimary : Brutal.textTertiary))
                        .overlay(Rectangle().strokeBorder(unlocked ? Brutal.ink : Brutal.textTertiary, lineWidth: 1.5))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!unlocked)
                .help(unlocked ? L10n.tr("Equip %@", accessory.label) : L10n.tr("%@ unlocks at level %@", accessory.label, "\(accessory.unlockLevel)"))
                .brutalInteractive(
                    label: accessory.label,
                    hint: unlocked ? L10n.tr("Equips this accessory") : L10n.tr("Unlocks at level %@", "\(accessory.unlockLevel)"),
                    value: selected ? L10n.tr("Equipped") : (unlocked ? L10n.tr("Available") : L10n.tr("Locked")),
                    selected: selected,
                    hitExpansion: 11
                )
            }

            Spacer()
        }
    }

    private func brutalStatBlock(_ title: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .brutalFont(size: 15, weight: .black, design: .monospaced, relativeTo: .headline)
                .foregroundStyle(Brutal.ink)

            Text(title)
                .brutalFont(size: 7.5, weight: .black, relativeTo: .caption2)
                .kerning(0.8)
                .foregroundStyle(Brutal.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Brutal.card)
        .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
        .background(Rectangle().fill(Brutal.ink).offset(x: Brutal.drop, y: Brutal.drop))
    }

    private func brutalPetRow(_ kind: PetKind) -> some View {
        let unlocked = state.petStats.isUnlocked(kind)
        let eggPhase = state.petStats.isEggPhase(kind)
        let isSelected = currentPetKind == kind
        let words = state.petStats.words(for: kind)

        return Button {
            guard unlocked else { return }
            selectPet(kind)
        } label: {
            HStack(spacing: 10) {
                Group {
                    if kind == .none {
                        Text("zZ")
                            .brutalFont(size: 11, weight: .black, relativeTo: .callout)
                            .foregroundStyle(Brutal.textTertiary)
                    } else if !unlocked {
                        PetThumb(kind: kind, pixel: 1.6, silhouette: true)
                    } else if eggPhase {
                        PetThumb(kind: kind, pixel: 1.8, asEgg: true)
                    } else {
                        PetThumb(kind: kind, pixel: 1.6)
                    }
                }
                .frame(width: 34, height: 26)

                Text(unlocked ? kind.label.uppercased() : "???")
                    .brutalFont(size: 11, weight: .black, relativeTo: .callout)
                    .kerning(0.8)
                    .foregroundStyle(unlocked ? Brutal.textPrimary : Brutal.textTertiary)

                Spacer()

                if !unlocked {
                    // YA-32: honest copy plus real progress, e.g. 120/500.
                    VStack(alignment: .trailing, spacing: 1) {
                        Text((kind.unlockRequirementText ?? "").uppercased())
                            .brutalFont(size: 8, weight: .black, design: .monospaced, relativeTo: .caption2)
                            .foregroundStyle(Brutal.dangerText)

                        if let requirement = kind.unlockRequirement {
                            Text(requirement.progressText(in: state.petStats))
                                .brutalFont(size: 8, weight: .black, design: .monospaced, relativeTo: .caption2)
                                .foregroundStyle(Brutal.textSecondary)
                        }
                    }
                } else if eggPhase {
                    Text(state.petStats.eggStartWords[kind.rawValue] == nil
                         ? L10n.tr("CLICK TO START HATCHING")
                         : "\(state.petStats.hatchProgress(kind))/\(PetStats.hatchTarget)")
                        .brutalFont(size: 8.5, weight: .black, design: .monospaced, relativeTo: .caption2)
                        .foregroundStyle(Brutal.dangerText)
                } else if kind != .none {
                    Text(L10n.tr("LVL %@", "\(petLevel(forWords: words))"))
                        .brutalFont(size: 9, weight: .black, design: .monospaced, relativeTo: .caption)
                        .foregroundStyle(isSelected ? Brutal.contentOnYellow : Brutal.blue)

                    Text(L10n.tr("%@W", "\(words)"))
                        .brutalFont(size: 9, weight: .black, design: .monospaced, relativeTo: .caption)
                        .foregroundStyle(Brutal.textTertiary)
                }

                Rectangle()
                    .fill(isSelected ? Brutal.green : Brutal.card)
                    .frame(width: 14, height: 14)
                    .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(isSelected ? Brutal.yellow : Brutal.card)
            .overlay(Rectangle().strokeBorder(unlocked ? Brutal.ink : Brutal.textTertiary, lineWidth: Brutal.border))
            .background(Rectangle().fill(Brutal.ink).offset(x: Brutal.drop, y: Brutal.drop))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!unlocked)
        .brutalInteractive(
            label: kind == .none ? L10n.tr("No pet") : kind.label,
            hint: unlocked ? L10n.tr("Selects this pet") : (kind.unlockRequirementText ?? L10n.tr("Locked")),
            value: petAccessibilityValue(kind: kind, selected: isSelected, unlocked: unlocked, eggPhase: eggPhase, words: words),
            selected: isSelected,
            hitExpansion: 0
        )
    }

    private func petAccessibilityValue(
        kind: PetKind,
        selected: Bool,
        unlocked: Bool,
        eggPhase: Bool,
        words: Int
    ) -> String {
        guard unlocked else {
            guard let requirement = kind.unlockRequirement else { return L10n.tr("Locked") }
            return L10n.tr("Locked, %@", requirement.progressText(in: state.petStats))
        }
        var parts = [selected ? L10n.tr("Selected") : L10n.tr("Available")]
        if kind != .none {
            parts.append(eggPhase ? L10n.tr("Egg phase") : L10n.tr("Level %@", "\(petLevel(forWords: words))"))
            parts.append(L10n.plural("%lld words", words))
        }
        return parts.joined(separator: ", ")
    }

}
