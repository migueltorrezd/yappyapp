import SwiftUI

extension BrutalistPopoverView {
    // MARK: - Pet and quests off (YA-31)

    static var petOffTitle: String { L10n.tr("PET AND QUESTS ARE OFF") }
    static var petOffBody: String {
        L10n.tr("No quests, pet news, jingles or confetti. Your words, streak and totals still count.")
    }

    var petOffNotice: some View {
        VStack(spacing: 14) {
            Spacer()

            VStack(spacing: 0) {
                Text(Self.petOffTitle)
                    .brutalFont(size: 9, weight: .black, relativeTo: .caption)
                    .kerning(1.2)
                    .foregroundStyle(Brutal.paper)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(Brutal.ink)

                Text(Self.petOffBody)
                    .brutalFont(size: 10, weight: .bold, relativeTo: .callout)
                    .foregroundStyle(Brutal.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .frame(maxWidth: .infinity)
                    .background(Brutal.card)
            }
            .overlay(Rectangle().strokeBorder(Brutal.ink, lineWidth: Brutal.border))
            .background(Rectangle().fill(Brutal.ink).offset(x: Brutal.drop, y: Brutal.drop))

            Button(L10n.tr("TURN ON PET AND QUESTS")) {
                setPetEnabled(true)
            }
            .buttonStyle(BrutalTextButtonStyle(fill: Brutal.blue, text: Brutal.paper))
            .brutalInteractive(
                label: L10n.tr("Turn on pet and quests"),
                hint: L10n.tr("Brings back the pet, daily quests and celebrations"),
                hitExpansion: 5
            )

            Spacer()
        }
        .padding(.trailing, Brutal.drop)
        .padding(.bottom, Brutal.drop)
    }

    /// Same draft-safe save path as selectPet: build from the live draft and
    /// cancel the pending autosave so no other edit is lost.
    func setPetEnabled(_ enabled: Bool) {
        autosaveTask?.cancel()
        var config = configDraft
        config.petEnabled = enabled
        onSaveConfig(config)
    }
}
