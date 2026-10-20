#if DEBUG
import Foundation

// Self-tests owned by the "pet" work track. Keep this track's new
// assertions here so parallel tracks never edit the same test lines.
extension SelfTests {
    static func petTrackTests() {
        test("petIntegration.tipsSkipPetsWhenOff") {
            let tips = (0..<(FeatureTips.items.count * 2)).map { FeatureTips.tip(at: $0, petEnabled: false).id }
            expect(!tips.contains("pets"), "Pet and quests off hides the pet tip")
            expect((0..<FeatureTips.items.count).contains { FeatureTips.tip(at: $0).id == "pets" }, "on, it still rotates in")
        }

        let calendar = PetStatsStore.calendar
        let noon = calendar.date(from: DateComponents(
            year: 2026, month: 6, day: 15, hour: 12, minute: 0, second: 0
        ))!
        func day(_ offset: Int, hour: Int = 12) -> Date {
            let shifted = calendar.date(byAdding: .day, value: offset, to: noon)!
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: shifted)!
        }

        // Scratch files live under the self-test base when one is given, so
        // nothing lands beside real app data.
        func scratchDirectory() -> URL {
            let root = ProcessInfo.processInfo.environment["YAPPYAPP_APP_SUPPORT_BASE"]
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.temporaryDirectory
            let directory = root.appendingPathComponent("pet-track-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }

        /// Every quest kind done on `date`'s day.
        func completeAllQuests(_ store: PetStatsStore, on date: Date) {
            let early = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: date)!
            store.record(words: 400, pet: "none", now: early)
            for _ in 0..<4 {
                store.record(words: 1, pet: "none", now: early)
            }
            store.markGlossaryTaught(now: early)
        }

        // MARK: YA-30

        test("pet.ya30.signedDayDifference") {
            expectEqual(PetStatsStore.signedDaysBetween("2026-06-15", and: "2026-06-14"), -1)
            expectEqual(PetStatsStore.signedDaysBetween("2026-06-14", and: "2026-06-16"), 2)
            expectEqual(PetStatsStore.signedDaysBetween("2026-12-31", and: "2027-01-01"), 1, "across a year end")
            expect(PetStatsStore.signedDaysBetween("", and: "2026-06-14") == nil, "missing day is nil")
            expectEqual(
                PetStatsStore.calendar.timeZone.identifier,
                TimeZone.autoupdatingCurrent.identifier,
                "day keys follow the live time zone"
            )
        }

        test("pet.ya30.effectiveDayHoldsOneDayBack") {
            var stats = PetStats()
            stats.lastDictationDay = PetStatsStore.dayString(day(1))
            expectEqual(stats.effectiveDay(asOf: day(0)), PetStatsStore.dayString(day(1)),
                        "one day back keeps the later recorded day")
            stats.lastDictationDay = PetStatsStore.dayString(day(3))
            expectEqual(stats.effectiveDay(asOf: day(0)), PetStatsStore.dayString(day(0)),
                        "a bigger jump back is a clock correction")
            stats.lastDictationDay = PetStatsStore.dayString(day(-1))
            expectEqual(stats.effectiveDay(asOf: day(0)), PetStatsStore.dayString(day(0)))
        }

        test("pet.ya30.travelWestKeepsStreakAndQuest") {
            let directory = scratchDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = PetStatsStore(url: directory.appendingPathComponent("stats.json"))

            store.record(words: 10, now: day(-1))
            store.record(words: 10, now: day(0, hour: 0))
            expectEqual(store.stats.streakDays, 2)
            completeAllQuests(store, on: day(0))
            let questsAfterFirstDay = store.stats.questsCompletedTotal

            // The wall clock falls back to the previous evening.
            let evening = day(-1, hour: 23)
            store.record(words: 5, now: evening)
            store.markGlossaryTaught(now: evening)
            expectEqual(store.stats.streakDays, 2, "the streak is not reset")
            expectEqual(store.stats.lastDictationDay, PetStatsStore.dayString(day(0)), "still counting on the later day")
            expectEqual(store.stats.questsCompletedTotal, questsAfterFirstDay, "the quest does not count twice")
            expect(!store.lastEvents.contains(.questCompleted), "no second quest event")
            expectEqual(store.stats.streakDisplayed(asOf: evening), 2)
        }

        // MARK: YA-31

        test("pet.ya31.configDefaultsAndDecode") {
            expect(AppConfig.defaultConfig.petEnabled, "the pet is on by default")
            var config = AppConfig.defaultConfig
            config.petEnabled = false
            let data = try JSONEncoder().encode(config)
            var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            expectEqual(object["petEnabled"] as? Bool, false, "the switch is persisted as petEnabled")
            expectEqual(try JSONDecoder().decode(AppConfig.self, from: data).petEnabled, false, "off round-trips")

            object.removeValue(forKey: "petEnabled")
            let legacy = try JSONSerialization.data(withJSONObject: object)
            expectEqual(try JSONDecoder().decode(AppConfig.self, from: legacy).petEnabled, true,
                        "an older config without the key keeps the pet on")
        }

        test("pet.ya31.offSilencesGamification") {
            expectEqual(PetGamification.celebrationIntensity(enabled: false, hasEvents: true, wordCount: 500), 0,
                        "no confetti while off")
            expectEqual(PetGamification.celebrationIntensity(enabled: true, hasEvents: true, wordCount: 2), 3)
            expectEqual(PetGamification.celebrationIntensity(enabled: true, hasEvents: false, wordCount: 3), 0)
            expectEqual(PetGamification.celebrationIntensity(enabled: true, hasEvents: false, wordCount: 50), 1)
            expectEqual(PetGamification.celebrationIntensity(enabled: true, hasEvents: false, wordCount: 100), 2)

            let off = PetGamification.announcement(
                for: [.questCompleted, .levelUp(3)], enabled: false, activePet: "cat", playSounds: true
            )
            expect(off.messages.isEmpty && !off.playJingle, "no messages or jingle while off")
            let on = PetGamification.announcement(
                for: [.questCompleted], enabled: true, activePet: "cat", playSounds: true
            )
            expectEqual(on.messages.count, 1)
            expect(on.playJingle, "jingle plays while on with sounds on")
            let muted = PetGamification.announcement(
                for: [.questCompleted], enabled: true, activePet: "cat", playSounds: false
            )
            expect(!muted.playJingle, "sounds off still mutes the jingle")

            expectEqual(PetGamification.overlayPet(enabled: false, active: .cat), PetKind.none, "no walking pet while off")
            expectEqual(PetGamification.overlayPet(enabled: true, active: .cat), PetKind.cat)
        }

        test("pet.ya31.storeKeepsPlainCountersOnly") {
            let directory = scratchDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = PetStatsStore(url: directory.appendingPathComponent("stats.json"))
            store.chooseStarter(.cat, now: day(0))

            let early = day(0, hour: 8)
            store.record(words: 1_200, pet: "cat", now: early, gamified: false)
            for _ in 0..<5 {
                store.record(words: 1, pet: "cat", now: early, gamified: false)
            }
            expect(store.lastEvents.isEmpty, "no events while off")
            expectEqual(store.stats.totalWords, 1_205, "lifetime words still count")
            expectEqual(store.stats.wordsTodayDisplayed(asOf: early), 1_205, "today still counts")
            expectEqual(store.stats.streakDays, 1, "the streak still counts")
            expectEqual(store.stats.questsCompletedTotal, 0, "no quest completes while off")
            expectEqual(store.stats.words(for: .cat), 0, "no pet XP while off")

            expect(store.markGlossaryTaught(now: early, gamified: false).isEmpty, "teaching a word is silent")
            expect(store.stats.glossaryTaughtDay.isEmpty, "the teach quest is not touched while off")

            // Turning it back on does not replay the 1,000 word milestone.
            store.record(words: 1, pet: "cat", now: early)
            expect(!store.lastEvents.contains { if case .milestone = $0 { return true } else { return false } },
                   "milestones passed while off never fire late")
        }

        test("pet.ya31.offNoticeCopy") {
            let copy = BrutalistPopoverView.petOffTitle + " " + BrutalistPopoverView.petOffBody
            expect(copy.contains("OFF"), "the Pet tab says it is off")
            // The TURN ON button sits right under the notice, so the copy does
            // not send people anywhere else; it says what still counts.
            expect(copy.contains("still count"), "the notice says what keeps counting")
            expect(!copy.contains("Setup"), "no detour to Setup while the button is right here")
            expect(!copy.contains("\u{2014}"), "no em dash in the notice")
        }

        // MARK: YA-32

        test("pet.ya32.unlockCopyAndProgress") {
            expectEqual(PetKind.ghost.unlockRequirementText, "500 words since your first pet")
            expectEqual(PetKind.dragon.unlockRequirementText, "10,000 words since your first pet")
            expectEqual(PetKind.none.unlockRequirementText, nil)
            for kind in PetKind.allCases {
                let text = kind.unlockRequirementText ?? ""
                expect(!text.lowercased().contains("lifetime"), "\(kind.rawValue) copy no longer says lifetime")
                expect(kind == .none || !text.isEmpty, "\(kind.rawValue) has unlock copy")
            }

            var stats = PetStats()
            stats.starter = PetKind.cat.rawValue
            stats.totalWords = 1_120
            stats.journeyStartWords = 1_000
            expectEqual(PetKind.ghost.unlockRequirement?.progressText(in: stats), "120/500")
            stats.totalWords = 9_000
            expectEqual(PetKind.ghost.unlockRequirement?.progressText(in: stats), "500/500", "progress clamps at the goal")
            expectEqual(PetKind.dragon.unlockRequirement?.progressText(in: stats), "8,000/10,000")

            // The copy and the gate read the same table.
            for kind in PetKind.allCases where kind.requiresUnlock && kind != .cat {
                guard let requirement = kind.unlockRequirement else {
                    expect(false, "\(kind.rawValue) has a requirement")
                    continue
                }
                expectEqual(stats.isUnlocked(kind), requirement.isMet(in: stats), "\(kind.rawValue) gate matches copy")
            }
        }

        // MARK: YA-37

        test("pet.ya37.overlayReservesSpace") {
            expectEqual(PetOverlayLayout.bottomReserve(for: .none), 0, "no pet, no reserve")
            for kind in PetKind.allCases where kind != .none {
                expect(PetOverlayLayout.bottomReserve(for: kind) >= 26, "\(kind.rawValue) keeps the bottom clear")
            }
        }

        // MARK: YA-64

        test("pet.ya64.glossaryQuestAnnouncesUnlock") {
            let directory = scratchDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = PetStatsStore(url: directory.appendingPathComponent("stats.json"))
            store.chooseStarter(.cat, now: day(0))
            completeAllQuests(store, on: day(0))
            completeAllQuests(store, on: day(1))
            expectEqual(store.stats.journeyQuests, 2)

            // Find the next day whose quest is the glossary one.
            var offset = 2
            while DailyQuest.forDay(PetStatsStore.dayString(day(offset))) != .teachAWord, offset < 40 {
                offset += 1
            }
            expectEqual(DailyQuest.forDay(PetStatsStore.dayString(day(offset))), .teachAWord)

            let events = store.markGlossaryTaught(now: day(offset))
            expect(events.contains(.questCompleted), "the glossary finishes the quest")
            expect(events.contains(.unlocked(.frog)), "the frog unlock is announced")
        }

        // MARK: YA-65

        test("pet.ya65.eggDoesNotLevelUp") {
            let directory = scratchDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = PetStatsStore(url: directory.appendingPathComponent("stats.json"))
            store.chooseStarter(.cat, now: day(0))
            expect(store.stats.isEggPhase(.cat), "the starter begins as an egg")

            store.record(words: 30, pet: "cat", now: day(0))
            expect(!store.lastEvents.contains { if case .levelUp = $0 { return true } else { return false } },
                   "an egg never levels up out loud")
            store.record(words: 600, pet: "cat", now: day(0))
            expect(store.lastEvents.contains(.hatched(.cat)), "the hatch is announced")
            expect(!store.lastEvents.contains { if case .levelUp = $0 { return true } else { return false } },
                   "the hatching dictation announces the hatch, not a level")
            store.record(words: 300, pet: "cat", now: day(0))
            expect(store.lastEvents.contains { if case .levelUp = $0 { return true } else { return false } },
                   "a hatched pet levels up normally")
        }

        // MARK: YA-66

        test("pet.ya66.newerSchemaStaysReadOnly") {
            let directory = scratchDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("stats.json")
            let future = Data(#"{"schemaVersion":999,"totalWords":73,"starter":"cat"}"#.utf8)
            try future.write(to: url)

            let store = PetStatsStore(url: url)
            expect(store.isReadOnly, "a newer schema opens read-only")
            expectEqual(store.readOnlySchemaVersion, 999)
            expectEqual(store.stats.totalWords, 73, "progress is shown, not reset to 0")
            expect(store.recovery == nil, "nothing is quarantined")

            store.record(words: 50, pet: "cat", now: day(0))
            store.chooseStarter(.dog, now: day(0))
            _ = store.markGlossaryTaught(now: day(0))
            expectEqual(store.stats.totalWords, 73, "nothing mutates the newer data")
            expectEqual(try Data(contentsOf: url), future, "the newer file is untouched on disk")
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            expectEqual(leftovers, ["stats.json"], "no quarantine or backup file appears")
        }

        // MARK: YA-67

        test("pet.ya67.streakSaverDayStillShowsStreak") {
            var stats = PetStats()
            stats.streakDays = 6
            stats.lastDictationDay = PetStatsStore.dayString(day(-2))
            expectEqual(stats.streakDisplayed(asOf: day(0)), 6, "one missed day is covered by the saver")
            stats.streakSaverWeek = PetStatsStore.weekString(day(0))
            expectEqual(stats.streakDisplayed(asOf: day(0)), 0, "a used saver cannot cover again this week")
            stats.streakSaverWeek = ""
            stats.lastDictationDay = PetStatsStore.dayString(day(-3))
            expectEqual(stats.streakDisplayed(asOf: day(0)), 0, "two missed days break the streak")
        }

        // MARK: YA-68

        test("pet.ya68.migrationKeepsXPAndSource") {
            let directory = scratchDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("stats.json")
            let legacy = Data(#"{"totalWords": 9000, "totalDictations": 300, "starter": "cat", "wordsByPet": {"cat": 900, "dog": 300}, "questsCompletedTotal": 8}"#.utf8)
            try legacy.write(to: url)

            let store = PetStatsStore(url: url)
            expectEqual(store.stats.words(for: .cat), 900, "starter XP survives the journey migration")
            expectEqual(store.stats.words(for: .dog), 300, "other pet XP survives too")
            expect(!store.stats.isUnlocked(.ghost), "lifetime words still do not pre-unlock")

            let preserved = PetStatsStore.migrationBackupURL(for: url)
            expectEqual(try Data(contentsOf: preserved), legacy, "the pre-migration bytes are kept")
            store.record(words: 10, pet: "cat", now: day(0))
            store.record(words: 10, pet: "cat", now: day(1))
            expectEqual(try Data(contentsOf: preserved), legacy, "later saves never overwrite them")

            // A second launch does not replace the preserved copy either.
            _ = PetStatsStore(url: url)
            expectEqual(try Data(contentsOf: preserved), legacy, "a relaunch keeps the original copy")
        }

        // MARK: YA-69

        test("pet.ya69.debugUnlocksOnlyInDebugBuilds") {
            let flag = [PetDebugAccess.environmentKey: "1"]
            expect(!PetDebugAccess.isEnabled(environment: flag, debugBuild: false), "release builds ignore the flag")
            expect(PetDebugAccess.isEnabled(environment: flag, debugBuild: true), "debug builds honor the flag")
            expect(!PetDebugAccess.isEnabled(environment: [:], debugBuild: true), "no flag, no debug unlocks")
            expect(!PetDebugAccess.isEnabled(environment: [PetDebugAccess.environmentKey: "nope"], debugBuild: true), "only yes values count")
        }

        // MARK: YA-70

        test("pet.ya70.recapSavesUniqueFilesOutsideDesktop") {
            let defaultDirectory = RecapCardRenderer.defaultDirectory()
            expectEqual(defaultDirectory.lastPathComponent, "YappYapp")
            expectEqual(defaultDirectory.deletingLastPathComponent().lastPathComponent, "Pictures")
            expect(!defaultDirectory.path.contains("/Desktop"), "never the Desktop")

            let directory = scratchDirectory().appendingPathComponent("Recaps", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
            let png = Data([0x89, 0x50, 0x4E, 0x47])

            let first = RecapCardRenderer.write(png, to: directory, date: day(0))
            let second = RecapCardRenderer.write(Data([1, 2, 3]), to: directory, date: day(0))
            guard case .saved(let firstURL) = first, case .saved(let secondURL) = second else {
                expect(false, "both saves succeed: \(first), \(second)")
                return
            }
            expect(firstURL != secondURL, "a second card gets a new name")
            expectEqual(firstURL.lastPathComponent, "YappYapp Recap \(PetStatsStore.dayString(day(0))).png")
            expectEqual(secondURL.lastPathComponent, "YappYapp Recap \(PetStatsStore.dayString(day(0))) 2.png")
            expectEqual(try Data(contentsOf: firstURL), png, "the first card is not overwritten")
            expect(first.statusText.contains("Pictures/YappYapp"), "the status says where it went")

            // A file where the folder should be: an honest write failure.
            let blocked = scratchDirectory()
            defer { try? FileManager.default.removeItem(at: blocked) }
            let notAFolder = blocked.appendingPathComponent("file")
            try Data([0]).write(to: notAFolder)
            let failed = RecapCardRenderer.write(png, to: notAFolder, date: day(0))
            guard case .writeFailed = failed else {
                expect(false, "a write failure is reported as one, got \(failed)")
                return
            }
            expect(failed.statusText.hasPrefix("Could not save the recap card"), "write failure copy")
            expect(!failed.statusText.contains("render"), "a write failure is not called a render failure")
            expect(RecapSaveResult.renderFailed.statusText.contains("render"), "render failures keep their own copy")
        }
    }
}
#endif
