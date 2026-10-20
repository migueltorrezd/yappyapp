# Third-Party Notices

This file is a release-readiness notice inventory, not legal advice. Verify licenses again before each public release.

## Project License

YappYapp's own source code is released under the MIT License. See `LICENSE`.

## Runtime and Build Dependencies

### whisper.cpp

- Purpose: local Whisper inference runtime (`whisper-cli` and `whisper-server`).
- Source: <https://github.com/ggml-org/whisper.cpp>
- License: MIT.
- Local evidence: `vendor/whisper.cpp/LICENSE`.
- Packaged notice: `Contents/Resources/Notices/ThirdParty/whisper.cpp-LICENSE.txt`.
- Distribution note: `scripts/package_app.sh` bundles `vendor/whisper.cpp/build/bin/whisper-cli` and `whisper-server` when present.

### llama.cpp

- Purpose: local runtime for the optional LLM cleanup pass (`llama-server`, which keeps the model warm, and the one-shot `llama-completion` fallback).
- Source: <https://github.com/ggml-org/llama.cpp>
- Version: release tag `v0.6.0`, commit `d81235049384534c167caea52b85a694f6103d14`, built by `scripts/bootstrap_llama_cpp.sh`.
- License: MIT. Bundled ggml code is part of the same repository and license.
- Local evidence: `vendor/llama.cpp/LICENSE`.
- Packaged notice: `Contents/Resources/Notices/ThirdParty/llama.cpp-LICENSE.txt`.
- Distribution note: `scripts/package_app.sh` bundles and signs `vendor/llama.cpp/build/bin/llama-completion`, `vendor/llama.cpp/build/bin/llama-server` and `vendor/llama.cpp/build/bin/llama-mtmd-cli` when present. All three helpers are static, Metal-enabled and arm64 only, and are built without HTTPS model downloads; the server is built without a web UI, and the app binds it to 127.0.0.1 behind a random per-launch path. `llama-mtmd-cli` is the one-shot audio helper for the Qwen3-ASR speech models.

### Code vendored inside whisper.cpp and llama.cpp

The bundled helpers compile in third-party code that ships inside those two
repositories under its own license:

- cpp-httplib (Copyright (c) 2017 yhirose), MIT: the HTTP layer of
  `whisper-server` and `llama-server`.
- nlohmann/json (Copyright (c) 2013-2025 Niels Lohmann), MIT: JSON handling in
  `whisper-server` and the llama.cpp helpers (`vendor/llama.cpp/licenses/LICENSE-jsonhpp`).
- miniaudio (David Reid), public domain or MIT-0, and stb_image (Sean Barrett),
  public domain or MIT: audio and image decoding in `llama-mtmd-cli`.
- Packaged notices: `Contents/Resources/Notices/ThirdParty/cpp-httplib-LICENSE.txt`,
  `nlohmann-json-LICENSE.txt` (sources in `packaging/notices/`) and every file in
  `vendor/llama.cpp/licenses/` as `llama.cpp-<name>.txt`.

### FluidAudio

- Purpose: Swift/CoreML audio framework used for Parakeet transcription.
- Source: <https://github.com/FluidInference/FluidAudio>
- License: Apache 2.0.
- Local evidence: `.build/checkouts/FluidAudio/LICENSE`.
- Additional local notices: `.build/checkouts/FluidAudio/ThirdPartyLicenses/fastcluster-LICENSE.md` and `.build/checkouts/FluidAudio/ThirdPartyLicenses/vbx-LICENSE.md`.
- Packaged notices: `Contents/Resources/Notices/ThirdParty/FluidAudio-LICENSE.txt`, `FluidAudio-fastcluster-LICENSE.md`, and `FluidAudio-vbx-LICENSE.md`.
- Distribution note: SwiftPM resolves FluidAudio from `Package.resolved`.

### Sparkle

- Purpose: in-app update checks and signed application updates.
- Source: <https://github.com/sparkle-project/Sparkle>
- License: MIT.
- Local evidence: `.build/checkouts/Sparkle/LICENSE`.
- Packaged notice: `Contents/Resources/Notices/ThirdParty/Sparkle-LICENSE.txt`.
- Distribution note: SwiftPM resolves Sparkle from `Package.resolved`; packaged builds embed `Sparkle.framework` and verify appcast signatures with the public EdDSA key in `Info.plist`.

### Swift Testing and SwiftSyntax (development only)

- Purpose: compile and discover the standalone pure-logic test target on both
  full Xcode and Command Line Tools installations.
- Sources: <https://github.com/swiftlang/swift-testing> and
  <https://github.com/swiftlang/swift-syntax>.
- License: Apache 2.0 with Runtime Library Exception.
- Local evidence: `.build/checkouts/swift-testing/LICENSE.txt` and
  `.build/checkouts/swift-syntax/LICENSE.txt`.
- Distribution note: these packages are test-only dependencies and are not
  linked into or copied into `YappYapp.app`.

## Model Assets

YappYapp does not commit Whisper or Parakeet model weights to this repository,
and the default public app package does not bundle model weights. It downloads
or uses locally installed models instead.

### Whisper GGML Models

- Download path: `scripts/install_model.sh` and in-app `ModelDownloadManager`.
- Source: <https://huggingface.co/ggerganov/whisper.cpp>
- Current Hugging Face API check in `docs/RELEASE_PROVENANCE.json` records license `mit`, public/non-gated state, and model-card revision `5359861c739e955e79d9a303bcbc70fb988958b1`.
- Integrity: YappYapp verifies registered SHA-1 values after in-app and `scripts/install_model.sh` downloads.
- Attribution: OpenAI Whisper model weights (MIT, <https://github.com/openai/whisper>), converted to GGML by the whisper.cpp project.

### Parakeet CoreML Models

- Download path: YappYapp's `ModelDownloadManager.parakeetDownloadPlan` and
  pinned Hugging Face tree/resolve endpoints. FluidAudio supplies the inference
  runtime and cache layout, but its own network path is forced offline at all
  times. It only loads a cache after YappYapp verifies the integrity manifest.
- Model catalog used by this app:
  - `FluidInference/parakeet-ultra-coreml` at `95eaa59a39d4394f047a4dc5cce480388a60d1b6`
  - `FluidInference/parakeet-tdt-0.6b-v3-coreml` at `aed02740059203c4a87495924f685de3722ae9ce`
  - `FluidInference/parakeet-tdt-0.6b-v2-coreml` at `ee09c569f73759e6d44c9bd16766f477b2b36d39`
  - `FluidInference/parakeet-tdt-ctc-110m-coreml` at `9bc92ead6e8f17eca92a869fd578ae76842b82ba`
  - `FluidInference/parakeet-0.6b-ja-coreml` at `2952296ff1da4a6d6a7aec545e226367db80c612`
- Current Hugging Face API check in `docs/RELEASE_PROVENANCE.json` records all five repos as public/non-gated with license `cc-by-4.0`.
- Parakeet Ultra attribution (CC-BY-4.0): "parakeet-ultra-coreml" is the Core ML
  conversion by FluidInference (<https://huggingface.co/FluidInference/parakeet-ultra-coreml>)
  of "parakeet-ultra" by moondream (<https://huggingface.co/moondream/parakeet-ultra>),
  itself a post-training of NVIDIA's "parakeet-tdt-0.6b-v3"
  (<https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3>). Licensed under
  Creative Commons Attribution 4.0 International
  (<https://creativecommons.org/licenses/by/4.0/>). YappYapp downloads the files
  unmodified and runs them as published.
- Attribution for the other Parakeet models (all CC-BY-4.0,
  <https://creativecommons.org/licenses/by/4.0/>, converted to Core ML by
  FluidInference and downloaded unmodified):
  - "parakeet-tdt-0.6b-v3-coreml", from NVIDIA's "parakeet-tdt-0.6b-v3"
    (<https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3>).
  - "parakeet-tdt-0.6b-v2-coreml", from NVIDIA's "parakeet-tdt-0.6b-v2"
    (<https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2>).
  - "parakeet-tdt-ctc-110m-coreml", from NVIDIA's "parakeet-tdt_ctc-110m"
    (<https://huggingface.co/nvidia/parakeet-tdt_ctc-110m>).
  - "parakeet-0.6b-ja-coreml", from NVIDIA's "parakeet-tdt_ctc-0.6b-ja"
    (<https://huggingface.co/nvidia/parakeet-tdt_ctc-0.6b-ja>).
- Release note: confirm current Hugging Face model-card license metadata and any NVIDIA upstream model terms before public distribution or model bundling.
- Integrity: YappYapp fetches each repository's recursive tree at the exact
  pinned revision from fixed `https://huggingface.co` URLs, ignores
  environment-controlled registry origins, and never attaches ambient Hugging
  Face credentials because every listed repository is public and non-gated. It
  rejects unsafe relative paths, downloads only from that revision, and verifies
  every selected file's declared size plus its Hugging Face LFS SHA-256 or Git
  blob SHA-1 before activation. It then writes an
  owner-only `.yappyapp-integrity-v1.json` cache manifest containing the repo,
  revision, file paths, sizes, algorithms, and digests. FluidAudio remains
  offline even when model downloads are allowed, so a load/recovery path cannot
  fetch mutable upstream content. Set `allowModelDownloads` to `false` to block
  YappYapp's pinned downloader too.

### Qwen Cleanup Model (Optional)

- Purpose: optional, fully local post-transcription cleanup through the bundled `llama-completion` runtime (or a user-chosen `llama-cli` build).
- Source: <https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF>.
- File: `qwen2.5-1.5b-instruct-q4_k_m.gguf` at revision `91cad51170dc346986eccefdc2dd33a9da36ead9`.
- License: Apache 2.0 according to the upstream model card; current provenance records the repository as public and non-gated.
- Integrity: YappYapp verifies the pinned file's SHA-1 before activation; the exact value is recorded in `docs/RELEASE_PROVENANCE.json`.
- Distribution note: the model is not bundled. The app downloads it only after the user picks a cleanup mode, and only when the cleanup runtime is present.

### Hy-MT2 Translation Models (Optional)

- Purpose: optional, fully local translation of a dictation into another language through the bundled `llama-completion` runtime.
- Sources: <https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF> (`Hy-MT2-1.8B-Q4_K_M.gguf`, revision `a0c709d9fac510f2c807aa3af52872340dc37a4a`) and <https://huggingface.co/tencent/Hy-MT2-7B-GGUF> (`Hy-MT2-7B-Q4_K_M.gguf`, revision `ab8472660ac61fac25f1af43fac2599d52a8a775`).
- License: Apache 2.0 according to the LICENSE.txt in each repository (Copyright (C) 2026 Tencent); both repositories are public and non-gated.
- Integrity: YappYapp verifies each file's SHA-256 against the Hugging Face LFS metadata before activation; the exact values are recorded in `docs/RELEASE_PROVENANCE.json`.
- Distribution note: the models are not bundled. The app downloads one only when the user asks (a translation target's DOWNLOAD, a MODELS row, or a SCAN MY MAC pick), and only when the llama.cpp runtime is present and model downloads are allowed.

### Qwen3-ASR Speech Models (Optional)

- Purpose: optional, fully local speech recognition in 52 languages and dialects (Chinese, Japanese, Korean, Arabic, Hindi and more) through the bundled `llama-server` and `llama-mtmd-cli` runtime.
- Sources: <https://huggingface.co/ggml-org/Qwen3-ASR-0.6B-GGUF> (revision `928ab958557df9aa2ef1c93e0e83c7ad0933fae2`: `Qwen3-ASR-0.6B-Q8_0.gguf` and `mmproj-Qwen3-ASR-0.6B-Q8_0.gguf`) and <https://huggingface.co/ggml-org/Qwen3-ASR-1.7B-GGUF> (revision `36a678687ba7d07a74ca70ccb0e36902e005fb80`: `Qwen3-ASR-1.7B-Q8_0.gguf` and `mmproj-Qwen3-ASR-1.7B-Q8_0.gguf`), converted from <https://huggingface.co/Qwen/Qwen3-ASR-0.6B> and <https://huggingface.co/Qwen/Qwen3-ASR-1.7B>.
- License: Apache 2.0 according to the upstream Qwen model cards (Alibaba Qwen team). The ggml-org conversions declare no license of their own and name those models as their base; all four repositories are public and non-gated.
- Integrity: YappYapp verifies each file's SHA-256 against the Hugging Face LFS metadata before activation; the exact values are recorded in `docs/RELEASE_PROVENANCE.json`.
- Distribution note: the models are not bundled. The app downloads one only when the user asks (a MODELS row), and only when the llama.cpp runtime is present and model downloads are allowed.

## Artwork

### Clawd pet

- Clawd, one of the unlockable pixel pets, is Anthropic's Claude Code mascot,
  redrawn as a pixel sprite and included as a fan tribute. YappYapp is not
  affiliated with or endorsed by Anthropic. Clawd and Claude are Anthropic's
  marks; the sprite will be removed on request.
- Source: `Sources/YappYapp/PetSprites.swift` (`clawdSprite`).

## Apple Frameworks

YappYapp links Apple platform frameworks through the macOS SDK, including AppKit, AVFoundation, ApplicationServices, AudioToolbox, Carbon, CoreAudio, and ServiceManagement.

## Maintainer Checklist

Before a public release:

- Confirm `./scripts/check_packaged_notices.sh` passes so full dependency
  license texts are included in generated release artifacts.
- Run `./scripts/check_hf_model_metadata.sh` and review any changed model-card terms before public release.
- Run `./scripts/check_no_model_weights.sh` before publishing default
  no-bundled-model releases.
- Include checksums for generated release archives.
- Confirm whether the release bundles `whisper.cpp` binaries or expects a system/Homebrew install.
- Confirm the release bundles `llama-completion` (`./scripts/bootstrap_llama_cpp.sh`) so LLM cleanup works without Homebrew.
- Confirm the release bundles `llama-mtmd-cli` and `llama-server` from the same build so the Qwen3-ASR speech models run.
