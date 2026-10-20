# Security Policy

YappYapp is a local-first macOS dictation app. Its most sensitive surfaces are microphone audio, transcript text, clipboard contents, Accessibility permissions, model downloads, and app signing.

## Supported Versions

Security fixes land on `main` and ship in the next release. Only the latest release is supported.

## Reporting a Vulnerability

Do not publish sensitive reports in public issues. Report privately through GitHub: open the repository's **Security** tab and choose **Report a vulnerability** (<https://github.com/migueltorrezd/yappyapp/security/advisories/new>).

Please include:

- macOS version and architecture.
- YappYapp version or commit.
- Whether you used `swift run` or `dist/YappYapp.app`.
- Output from `./scripts/doctor.sh`.
- Clear reproduction steps.
- Whether microphone, Accessibility, or clipboard data is involved.

Do not attach private recordings or transcripts unless you have intentionally created a synthetic reproduction sample.

## What Counts as Security-Sensitive

- Transcript or audio written to disk without explicit user intent.
- Audio or transcripts leaving the machine unexpectedly.
- Pasting into password fields or secure input.
- Clipboard restoration exposing or erasing sensitive clipboard state incorrectly.
- Model download tampering, wrong-source downloads, or silent fallback to untrusted binaries.
- Code signing, notarization, quarantine, or launch-at-login behavior that misleads users.
- App support files created with unsafe permissions.

## Privacy Design Expectations

- Runtime transcription should happen locally.
- Temporary WAV files should be deleted after transcription, failure, or cancellation.
- Transcript history should remain in memory only.
- Network access should be limited to model downloads and update checks, as documented in the README "Network use" section. Links the user clicks (such as HELP > MADE BY) open in the default browser; the app does not fetch them.
- New features must make data retention and network behavior clear in user-facing docs.
