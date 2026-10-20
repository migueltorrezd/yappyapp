# Model Distribution Policy

YappYapp is local-first, but model setup can use the network. Public releases
should keep those two facts separate and explicit.

## Default Public Build

- Do not commit Whisper or Parakeet model weights to this repository.
- The initial public app package does not bundle Whisper or Parakeet model weights. It may bundle only the `whisper.cpp` runtime helpers (`whisper-cli` and `whisper-server`).
- The optional Qwen cleanup GGUF is not bundled. Its runtime is: the app ships
  a static, Metal-enabled `llama-completion` and `llama-server` built from the
  llama.cpp release pinned in `docs/RELEASE_PROVENANCE.json`
  (`scripts/bootstrap_llama_cpp.sh`). The server keeps the model warm on
  127.0.0.1 while cleanup is on; llama-completion is the fallback.
  When a cleanup mode is picked and that runtime is present, the app downloads
  the provenance-pinned GGUF with progress and a cancel, and verifies its
  registered SHA-1 before activation. Without the runtime it says "Needs the
  cleanup runtime" and downloads nothing.
- The optional Qwen3-ASR speech models (two GGUFs each: the model and its
  audio projector, from `ggml-org/Qwen3-ASR-0.6B-GGUF` and
  `ggml-org/Qwen3-ASR-1.7B-GGUF`) are not bundled either. They run on the same
  pinned runtime, which also ships `llama-mtmd-cli` for one-shot runs. The app
  downloads a model only from a MODELS row, only with that runtime present and
  `allowModelDownloads` on, and verifies each file's registered SHA-256 before
  activation. For a managed install, place both files of a size in
  `~/Library/Application Support/YappYapp/models/`; the app hashes them at
  launch and uses them once they match.
- Ship the app with `allowModelDownloads: true` by default.
- Store Whisper models in `~/Library/Application Support/YappYapp/models/`.
- Verify downloaded Whisper models against the SHA-1 values registered in
  `ModelCatalog.swift`.
- Reject unsupported `scripts/install_model.sh` model names before network
  access so typoed or unregistered downloads do not bypass checksum
  verification.
- `scripts/doctor.sh` verifies the configured known Whisper model checksum
  and warns for custom model filenames without a registered checksum.
- Let YappYapp fetch Parakeet/CoreML files into FluidAudio's cache layout from
  exact repository revisions at a fixed `https://huggingface.co` origin. The
  downloader must not honor environment-controlled registry URLs or attach
  ambient Hugging Face credentials for these public/non-gated repositories. It
  must verify declared sizes and the Hugging Face LFS SHA-256 or Git blob SHA-1
  for every selected file, then write the owner-only
  `.yappyapp-integrity-v1.json` cache manifest before activation.
- Keep FluidAudio's own downloader forced offline at all times. Recording and
  `AsrModels.load` must reject a Parakeet cache until YappYapp's manifest check
  succeeds, so FluidAudio load/recovery cannot fetch mutable upstream content.
- Keep runtime transcription local after the selected model is installed.

## Offline Or Managed Build

For air-gapped or managed environments:

1. Install Whisper models ahead of time with `scripts/install_model.sh` or an
   MDM/package-managed model installer.
2. If Parakeet is enabled, pre-cache the selected FluidAudio/CoreML model for
   the user before first launch, including a valid YappYapp integrity manifest.
3. Set `allowModelDownloads` to `false` in `config.json`.
4. Verify `scripts/offline_config_smoke.sh` passes. It creates an isolated
   support folder, disables downloads in `config.json`, installs a placeholder
   managed model, re-runs first-launch preparation, and confirms `doctor.sh`
   reports downloads disabled plus at least one local model.

FluidAudio stays offline whether or not downloads are enabled. When downloads
are disabled, YappYapp also refuses its own in-app Whisper and pinned Parakeet
fetches and changes model rows to a manual-install state instead of offering
download buttons. An unverified selected Parakeet model is treated as not ready
until the FluidAudio cache is preseeded with a valid YappYapp integrity manifest
or YappYapp downloads are re-enabled.

`scripts/doctor.sh` asks the packaged app to inspect FluidAudio's local
Parakeet cache without downloading anything. It fails managed/offline installs
when a selected Parakeet model is missing while downloads are disabled, and it
uses a timeout so stale app bundles that lack the diagnostic flag cannot hang
the doctor.

## Release Requirements

Every public release should document:

- Whether model downloads are enabled by default.
- Which Whisper model filenames are exposed in the picker.
- The checksum source and checksum values used by the release.
- The vendored `whisper.cpp` revision, when a runtime is bundled.
- Whether Parakeet models are supported, pre-cached, or disabled for the build.
- Whether optional local LLM cleanup is supported and the pinned Qwen model
  revision/checksum used by that build.

`docs/RELEASE_PROVENANCE.json` records the current app metadata, project
license, Swift package pin, vendored `whisper.cpp` revision, bundled runtime
hashes, Whisper model checksums, and pinned Parakeet repositories. Run
`./scripts/check_provenance.sh` before publishing; `./scripts/verify_release.sh`
runs it automatically.

`./scripts/check_hf_model_metadata.sh` performs the networked Hugging Face API
check for model-card license, revision, public/private state, and gated state.
Run it before a public release and update `docs/RELEASE_PROVENANCE.json` only
after reviewing any upstream model-card changes.

`./scripts/check_no_model_weights.sh` enforces the default source/package
policy: no tracked or unignored source-tree model-weight files and no model-weight files inside
`dist/YappYapp.app`. It runs automatically from `./scripts/verify_release.sh`.

`./scripts/check_ignore_policy.sh` verifies `.gitignore` also catches common
local model-weight formats before they appear in the source scan. It checks
representative Whisper, Parakeet/CoreML, ONNX, audio, transcript, release, and
support-report paths while making sure normal source and docs files remain
trackable.

If a future release intentionally pre-bundles any model, update this policy,
the checker allowlist, third-party notices, release provenance, checksums, and
release notes in the same change.

## Do Not Do This Casually

- Do not bundle model weights without reviewing the model license and artifact
  size for that exact release.
- Do not add new downloadable model URLs without a pinned revision and a
  verified digest for every activated file.
- Do not market the app as network-free unless the build ships with downloads
  disabled and models preinstalled.
