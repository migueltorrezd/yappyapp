import AppKit
import SwiftUI

/// Shareable weekly recap card rendered as a PNG in Pictures: pixel pet,
/// big numbers, brutal paper styling. Built for posting.
struct RecapCardView: View {
    let stats: PetStats
    let kind: PetKind

    // FIX staleDayDisplay: normalize the day/week-scoped numbers against now so
    // the card never overstates the current week or a broken streak.
    private var weekIsCurrent: Bool {
        stats.weekKey == PetStatsStore.weekString(Date())
    }

    private var streak: Int {
        stats.streakDisplayed()
    }

    private var topPet: (kind: PetKind, words: Int)? {
        let pairs = PetKind.allCases.compactMap { candidate -> (PetKind, Int)? in
            let words = stats.words(for: candidate)
            return words > 0 ? (candidate, words) : nil
        }
        return pairs.max { $0.1 < $1.1 }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("YAPPYAPP")
                    .font(.system(size: 26, weight: .black))
                    .kerning(2)
                    .foregroundStyle(Brutal.paper)

                Spacer()

                Text(L10n.tr("WEEKLY RECAP"))
                    .font(.system(size: 13, weight: .black))
                    .kerning(1.5)
                    .foregroundStyle(Brutal.yellow)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
            .background(Brutal.ink)

            HStack(spacing: 24) {
                VStack(spacing: 8) {
                    if kind != .none {
                        PetThumb(kind: kind, pixel: 5)

                        Text(kind.label.uppercased())
                            .font(.system(size: 14, weight: .black))
                            .kerning(1)
                            .foregroundStyle(Brutal.ink)

                        Text(L10n.tr("LVL %@", "\(petLevel(forWords: stats.words(for: kind)))"))
                            .font(.system(size: 11, weight: .black, design: .monospaced))
                            .foregroundStyle(Brutal.blue)
                    } else {
                        Text(L10n.tr("NO PET"))
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(Brutal.textTertiary)
                    }
                }
                .frame(width: 180)
                .frame(maxHeight: .infinity)
                .background(Brutal.yellow)
                .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: 3))

                VStack(alignment: .leading, spacing: 12) {
                    // FIX staleDayDisplay: weekWords/streakDays only roll over
                    // inside record(). A recap saved after the week ended must
                    // not label a stale count "THIS WEEK" or show a broken
                    // streak as current. Read normalized against now, and word
                    // the week label to match the counter's actual week.
                    recapStat("\(stats.weekWords)", weekIsCurrent ? L10n.tr("WORDS THIS WEEK") : L10n.tr("WORDS LAST ACTIVE WEEK"))
                    recapStat(L10n.plural("%lld DAYS", streak), L10n.tr("CURRENT STREAK"))
                    recapStat("\(stats.totalWords)", L10n.tr("WORDS ALL TIME"))
                    // MARKER privacyAndTimeSaved: recap time-saved stat
                    recapStat(TimeSavedMath.shortLabel(words: stats.totalWords), L10n.tr("TIME SAVED TYPING"))

                    if let topPet, topPet.kind != kind {
                        Text(L10n.tr("TOP PET: %@ (%@ WORDS)", topPet.kind.label.uppercased(), "\(topPet.words)"))
                            .font(.system(size: 10, weight: .black))
                            .kerning(0.8)
                            .foregroundStyle(Brutal.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(24)
            .frame(maxHeight: .infinity)
            .background(Brutal.paper)

            HStack {
                Text(L10n.tr("100% LOCAL DICTATION. YOUR VOICE NEVER LEAVES YOUR MAC."))
                    .font(.system(size: 9, weight: .black))
                    .kerning(1)
                    .foregroundStyle(Brutal.paper.opacity(0.8))

                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 10)
            .background(Brutal.ink)
        }
        .frame(width: 720, height: 400)
    }

    private func recapStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 32, weight: .black, design: .monospaced))
                .foregroundStyle(Brutal.ink)

            Text(label)
                .font(.system(size: 10, weight: .black))
                .kerning(1.2)
                .foregroundStyle(Brutal.textTertiary)
        }
    }
}

/// What happened to a recap card save, so the status line can be honest.
enum RecapSaveResult: Equatable {
    case saved(URL)
    case renderFailed
    case writeFailed(String)

    var statusText: String {
        switch self {
        case .saved(let url):
            return L10n.tr("Recap card saved to Pictures/YappYapp as %@.", url.lastPathComponent)
        case .renderFailed:
            return L10n.tr("Could not render the recap card.")
        case .writeFailed(let reason):
            return L10n.tr("Could not save the recap card: %@", reason)
        }
    }
}

enum RecapCardRenderer {
    /// YA-70: cards go to ~/Pictures/YappYapp, never the Desktop, so saving
    /// never triggers the Desktop folder permission prompt.
    static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let pictures = fileManager.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Pictures", isDirectory: true)
        return pictures.appendingPathComponent("YappYapp", isDirectory: true)
    }

    /// "YappYapp Recap 2026-10-16.png", then "... 2.png", "... 3.png": an
    /// earlier card is never overwritten.
    static func uniqueURL(in directory: URL, date: Date, fileManager: FileManager = .default) -> URL {
        let base = "YappYapp Recap \(PetStatsStore.dayString(date))"
        var candidate = directory.appendingPathComponent("\(base).png")
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(counter).png")
            counter += 1
        }
        return candidate
    }

    /// Writes already rendered PNG bytes without replacing an existing file.
    static func write(
        _ png: Data,
        to directory: URL,
        date: Date = Date(),
        fileManager: FileManager = .default
    ) -> RecapSaveResult {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = uniqueURL(in: directory, date: date, fileManager: fileManager)
            try png.write(to: url, options: .withoutOverwriting)
            return .saved(url)
        } catch {
            return .writeFailed(error.localizedDescription)
        }
    }

    /// The recap card as PNG bytes at 2x, or nil when rendering fails.
    @MainActor
    static func renderPNG(stats: PetStats, kind: PetKind) -> Data? {
        let renderer = ImageRenderer(content: RecapCardView(stats: stats, kind: kind))
        renderer.scale = 2

        guard let nsImage = renderer.nsImage,
              let tiff = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }
        return png
    }

    /// Renders the recap card and saves it under a new name in `directory`.
    @MainActor
    static func save(
        stats: PetStats,
        kind: PetKind,
        to directory: URL = defaultDirectory(),
        date: Date = Date()
    ) -> RecapSaveResult {
        guard let png = renderPNG(stats: stats, kind: kind) else { return .renderFailed }
        return write(png, to: directory, date: date)
    }
}
