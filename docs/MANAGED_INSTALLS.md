# Managed installs

Roll YappYapp out to a fleet and pin the settings that matter to IT. A
configuration profile (installed by your MDM or by hand) can force a small set
of settings. Forced settings win over the user's `config.json`, show a
**LOCKED** tag in the app, and cannot be changed from the UI.

YappYapp never writes a forced value into `config.json`. Remove the profile
and each user gets their own previous choice back.

## Where YappYapp reads from

- Preference domain: the app's bundle ID, `app.yappyapp.YappYapp`.
- Only forced (managed) values count. YappYapp asks macOS whether each key is
  forced (`CFPreferencesAppValueIsForced`), so a plain `defaults write` by the
  user does not lock anything.
- Values are read at launch and each time YappYapp reloads its settings.
  Quit and reopen YappYapp to apply a new profile right away.

## Keys

| Key | Type | Effect |
| --- | --- | --- |
| `allowModelDownloads` | Boolean | `false` blocks every in-app model download. Use it for offline or air-gapped Macs and install models ahead of time ([MODEL_DISTRIBUTION.md](MODEL_DISTRIBUTION.md)). |
| `automaticUpdateChecks` | Boolean | `false` turns off the daily update check. Use it when you ship updates through MDM. |
| `selectedModel` | String | The transcription model. A catalog ID (`parakeet-ultra`, `parakeet-v3`, `parakeet-v2`, `parakeet-110m`, `parakeet-ja`, `large-v3-turbo`, `large-v3`, `medium`, `small`, `base`, `tiny`), a `parakeet://` model URL from the catalog, or an absolute path to a Whisper `.bin` file. The user cannot switch models while this is set. |
| `language` | String | Dictation language: `auto`, `en`, `fr`, `es` or `nl`. |
| `petEnabled` | Boolean | `false` turns the pet off and locks the Pet tab. `true` leaves the choice to the user. |
| `autoPaste` | Boolean | Controls AUTO-PASTE INTO THE ACTIVE APP. `false` keeps dictation on the clipboard only, in every app. |
| `learnFromFixes` | Boolean | Controls LEARN FROM MY FIXES. `false` stops YappYapp from reading back the text it pasted, so it never learns words from corrections. `true` keeps it on. |
| `numberStyle` | String | Controls NUMBERS: `spoken`, `digits` or `words`. App profiles cannot override it while it is set. |

Values YappYapp cannot use are ignored, and that setting stays unlocked. That
covers an unknown model ID, a language outside the list, a relative model
path, or a Boolean written as text other than `true`, `false`, `yes`, `no`,
`1` or `0`.

Per-app profiles never beat a forced value. A profile that asks for a
different language, model or paste behavior in one app gets the forced value
for that setting there too; its other choices still apply.

## Sample profile

Save as `YappYapp-Managed.mobileconfig`, replace both `PayloadUUID` values with
fresh UUIDs (`uuidgen`), and upload it to your MDM as a custom settings
payload. Delete any key you do not want to force.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadType</key>
  <string>Configuration</string>
  <key>PayloadVersion</key>
  <integer>1</integer>
  <key>PayloadIdentifier</key>
  <string>com.example.yappyapp.managed</string>
  <key>PayloadUUID</key>
  <string>REPLACE-WITH-UUID-1</string>
  <key>PayloadDisplayName</key>
  <string>YappYapp settings</string>
  <key>PayloadScope</key>
  <string>System</string>
  <key>PayloadContent</key>
  <array>
    <dict>
      <key>PayloadType</key>
      <string>app.yappyapp.YappYapp</string>
      <key>PayloadVersion</key>
      <integer>1</integer>
      <key>PayloadIdentifier</key>
      <string>com.example.yappyapp.managed.settings</string>
      <key>PayloadUUID</key>
      <string>REPLACE-WITH-UUID-2</string>
      <key>PayloadDisplayName</key>
      <string>YappYapp</string>
      <key>allowModelDownloads</key>
      <false/>
      <key>automaticUpdateChecks</key>
      <false/>
      <key>selectedModel</key>
      <string>parakeet-v3</string>
      <key>language</key>
      <string>en</string>
      <key>petEnabled</key>
      <false/>
      <key>autoPaste</key>
      <true/>
      <key>learnFromFixes</key>
      <false/>
    </dict>
  </array>
</dict>
</plist>
```

Some MDMs prefer the older `com.apple.ManagedClient.preferences` payload with
`Forced` / `mcx_preference_settings`. Both end up in the same managed domain,
and YappYapp reads either.

## Check it on one Mac

After the profile installs:

```sh
# Shows the forced values macOS holds for YappYapp.
defaults read /Library/Managed\ Preferences/app.yappyapp.YappYapp
```

Open YappYapp. Forced settings carry the LOCKED tag and their controls are
disabled. A forced model shows "Your organization picks the model on this Mac."
at the top of the Models tab.

## Related settings for managed Macs

- Helper programs: YappYapp runs `whisper-cli`, `whisper-server`,
  `llama-completion` and `llama-cli` only from inside the app bundle or from an absolute path set in
  `config.json`. It refuses relative paths, paths with `..`, and files that
  other users can modify or that belong to another user. Prefer the bundled
  runtime; if you point at a Homebrew install, keep it owned by the user or
  root and not group-writable.
- Damaged settings: if `config.json` is cut short or edited by hand into an
  invalid state, YappYapp keeps every readable value, restores the rest from
  its last saved copy (`config.json.last-good`), keeps the damaged file as
  `config.json.corrupt-N`, and shows a one-time notice. A lost
  `allowModelDownloads` value fails closed (downloads off). Forced values from
  the profile apply on top, as always.
- Start at login: macOS can hold the login item for approval. YappYapp says so
  and links to System Settings > General > Login Items. To pre-approve, add a
  Service Management (`com.apple.servicemanagement`) payload with a rule for
  the team identifier that signs your build.
