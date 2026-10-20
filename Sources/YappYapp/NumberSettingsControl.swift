import SwiftUI

/// NUMBERS: SETUP > DICTATION > LANGUAGE AND TEXT. Three choices, the line
/// for the picked one, and a tiny "you say, it writes" example.
struct NumberSettingsControl: View {
    @Binding var style: NumberStyle

    var body: some View {
        VStack(alignment: .leading, spacing: BrutalControl.innerSpacing) {
            BrutalRowLabel(L10n.tr("NUMBERS"))
            BrutalSegmented(
                choices: NumberStyle.allCases.map { option in
                    BrutalChoice(
                        value: option,
                        title: option.label,
                        accessibilityLabel: L10n.tr("Numbers %@", option.label.lowercased()),
                        hint: option.summary
                    )
                },
                selection: style,
                hint: style.summary
            ) { style = $0 }
            SaidWrittenExplainer(summary: style.summary, example: style.example)
        }
    }
}
