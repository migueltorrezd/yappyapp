import SwiftUI

extension BrutalistPopoverView {
    // TEXT-SIZE: four-step type scale chooser in SETUP > APP. The draft
    // drives the popover environment, so a tap resizes the UI immediately.
    var textSizeRow: some View {
        VStack(alignment: .leading, spacing: BrutalControl.innerSpacing) {
            BrutalRowLabel(L10n.tr("TEXT SIZE"))
            BrutalSegmented(
                choices: BrutalTextSize.allCases.map { size in
                    BrutalChoice(
                        value: size,
                        title: size.label,
                        accessibilityLabel: L10n.tr("Text size %@", size.label.lowercased())
                    )
                },
                selection: BrutalTextSize(configValue: configDraft.textSize),
                hint: L10n.tr("Sets the size of text in YappYapp")
            ) { configDraft.textSize = $0.rawValue }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
