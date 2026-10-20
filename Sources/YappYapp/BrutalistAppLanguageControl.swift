import SwiftUI

extension BrutalistPopoverView {
    // L10N (YA-42): "App language" chooser in SETUP > APP. It changes the
    // interface only; dictation keeps its own language setting. Five names
    // do not fit one line, so it is a dropdown. The helper switches before
    // the draft changes, so the next render is translated.
    var appLanguageRow: some View {
        VStack(alignment: .leading, spacing: BrutalControl.innerSpacing) {
            BrutalRowLabel(L10n.tr("APP LANGUAGE"))
            BrutalPicker(
                choices: AppLanguage.allCases.map { language in
                    BrutalChoice(
                        value: language,
                        title: language.chipLabel,
                        accessibilityLabel: L10n.tr("App language %@", language.chipLabel.lowercased())
                    )
                },
                selection: AppLanguage(configValue: configDraft.appLanguage),
                accessibilityLabel: L10n.tr("App language"),
                hint: L10n.tr("Sets the language of YappYapp's menus and screens")
            ) { language in
                L10n.apply(language.rawValue)
                configDraft.appLanguage = language.rawValue
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
