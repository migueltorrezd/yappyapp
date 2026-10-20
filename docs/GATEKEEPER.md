<!-- GATEKEEPER-DOC-M2 canonical first-open guidance -->
# Opening YappYapp The First Time

## Release builds (0.4.0 and later)

YappYapp release DMGs from 0.4.0 on are signed with an Apple Developer ID and
notarized by Apple. Drag YappYapp to Applications and double-click it. macOS
asks once whether you want to open an app downloaded from the internet; click
Open. There is no Open Anyway step. Dictation audio and transcripts are
processed on your Mac.

If you update from 0.3.x, macOS asks for Accessibility (and possibly the
microphone) once more, because the app's signature changed. Turn YappYapp on
again in System Settings > Privacy & Security > Accessibility.

## Builds that are not notarized

Older releases (0.3.x), ad-hoc release candidates from CI and builds you make
from source are not notarized. macOS shows a warning the first time you open
one. The warning means Apple has not verified that build's developer identity;
it is not a malware finding.

You only do this once per build. After the first open, YappYapp launches
normally with a plain double-click.

### Why You See This Warning

macOS flags any app it cannot trace to a known, notarized developer. This is a
check on who built the app, not a check that found a problem inside it.
Transcription runs locally. Network access is limited to documented model
downloads and signed update checks; dictation audio and transcript content are
not sent to those services.

### Open YappYapp (macOS 15 Sequoia and macOS 26 Tahoe)

1. Double-click YappYapp in Applications. macOS blocks it. Click Done.
2. Open System Settings, then [Privacy & Security](x-apple.systempreferences:com.apple.preference.security?Privacy).
3. Scroll down to the message "YappYapp was blocked to protect your Mac".
4. Click Open Anyway.
5. Authenticate with Touch ID or your password.
6. Click Open in the final dialog.

That is it. The next launch is a normal double-click.

### Open YappYapp (macOS 14 Sonoma)

1. In Applications, right-click (or Control-click) YappYapp.
2. Choose Open.
3. In the dialog, click Open.

That is it. The next launch is a normal double-click.

### If macOS Says YappYapp Is Damaged Or Cannot Be Opened

This is the download quarantine flag macOS adds to an app that is not notarized
and came from the internet. It is not real damage. Repeat the steps above for your macOS
version.

## What You Never Need To Do

You never disable Gatekeeper for your whole Mac, and you never run YappYapp as an
administrator to dictate. If any instructions ask you to do either of those,
ignore them.

## Only Install Trusted Builds

Only install an artifact obtained from a trusted channel, and verify its
published SHA-256 checksum before overriding Gatekeeper for a build that is
not notarized.

## Do Not Strip The Quarantine Flag

Earlier instructions suggested removing the `com.apple.quarantine` flag with
`xattr` to skip the first-open prompt. Do not do that. It skips Gatekeeper's
first-launch check for that copy entirely, and managed Macs often block or
flag the command. The Open Anyway step above is the
supported path, and you only do it once.
