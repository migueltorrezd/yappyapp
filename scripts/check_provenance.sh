#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT_DIR"

ruby <<'RUBY'
require "json"
require "open3"
require "digest"

root = Dir.pwd
manifest_path = File.join(root, "docs/RELEASE_PROVENANCE.json")
manifest = JSON.parse(File.read(manifest_path))
errors = []

def sh(*args)
  stdout, stderr, status = Open3.capture3(*args)
  raise "#{args.join(" ")} failed: #{stderr}" unless status.success?
  stdout.strip
end

def expect(errors, condition, message)
  errors << message unless condition
end

app = manifest.fetch("app")
plist = File.join(root, "dist/YappYapp.app/Contents/Info.plist")
if File.exist?(plist)
  bundle_id = sh("plutil", "-extract", "CFBundleIdentifier", "raw", plist)
  bundle_name = sh("plutil", "-extract", "CFBundleName", "raw", plist)
  short_version = sh("plutil", "-extract", "CFBundleShortVersionString", "raw", plist)
  bundle_version = sh("plutil", "-extract", "CFBundleVersion", "raw", plist)
  expect(errors, bundle_id == app.fetch("bundle_identifier"), "bundle identifier mismatch: #{bundle_id}")
  expect(errors, bundle_name == app.fetch("name"), "bundle name mismatch: #{bundle_name}")
  expect(errors, short_version == app.fetch("short_version"), "short version mismatch: #{short_version}")
  expect(errors, bundle_version == app.fetch("bundle_version"), "bundle version mismatch: #{bundle_version}")
end

license = manifest.fetch("project_license")
license_path = File.join(root, license.fetch("file"))
expect(errors, File.exist?(license_path), "missing project license: #{license.fetch("file")}")
if File.exist?(license_path)
  expect(errors, File.read(license_path).include?("MIT License"), "project license does not look like MIT")
end

resolved = JSON.parse(File.read(File.join(root, "Package.resolved")))
pins = resolved.fetch("pins").each_with_object({}) { |pin, acc| acc[pin.fetch("identity")] = pin }
manifest.fetch("swift_package_dependencies").each do |dep|
  pin = pins[dep.fetch("identity")]
  expect(errors, !pin.nil?, "Package.resolved missing #{dep.fetch("identity")}")
  next unless pin

  state = pin.fetch("state")
  expect(errors, pin.fetch("location") == dep.fetch("source"), "#{dep.fetch("identity")} source mismatch")
  expect(errors, state.fetch("version") == dep.fetch("version"), "#{dep.fetch("identity")} version mismatch")
  expect(errors, state.fetch("revision") == dep.fetch("revision"), "#{dep.fetch("identity")} revision mismatch")
  expect(errors, File.exist?(File.join(root, dep.fetch("local_license"))), "missing dependency license: #{dep.fetch("local_license")}")
end

manifest.fetch("bundled_runtimes").each do |runtime|
  if runtime.fetch("name") == "whisper.cpp"
    actual_revision = sh("git", "-C", File.join(root, "vendor/whisper.cpp"), "rev-parse", "HEAD")
    expect(errors, actual_revision == runtime.fetch("revision"), "whisper.cpp revision mismatch: #{actual_revision}")
  end
  # LLM-CLEANUP (YA-10): the bundled llama.cpp runtime is pinned to a release
  # tag and the exact commit that tag pointed at.
  if runtime.fetch("name") == "llama.cpp"
    expect(errors, runtime.fetch("tag", "").match?(/\Av\d+\.\d+\.\d+\z/), "llama.cpp provenance is missing its release tag")
    expect(errors, runtime.fetch("license") == "MIT", "llama.cpp license must be MIT")
    actual_revision = sh("git", "-C", File.join(root, "vendor/llama.cpp"), "rev-parse", "HEAD")
    expect(errors, actual_revision == runtime.fetch("revision"), "llama.cpp revision mismatch: #{actual_revision}")
  end

  expect(errors, File.exist?(File.join(root, runtime.fetch("local_license"))), "missing runtime license: #{runtime.fetch("local_license")}")
  runtime.fetch("artifacts").each do |artifact|
    artifact_path = File.join(root, artifact.fetch("path"))
    expect(errors, File.exist?(artifact_path), "missing runtime artifact: #{artifact.fetch("path")}")
    next unless File.exist?(artifact_path)

    actual = Digest::SHA256.file(artifact_path).hexdigest
    expect(errors, actual == artifact.fetch("sha256"), "runtime artifact hash mismatch for #{artifact.fetch("path")}: #{actual}")
  end
end

catalog = File.read(File.join(root, "Sources/YappYapp/ModelCatalog.swift"))
whisper_source = manifest.fetch("model_sources").fetch("whisper")
whisper_source.fetch("models").each do |model|
  expect(errors, catalog.include?("id: \"#{model.fetch("id")}\""), "model catalog missing id #{model.fetch("id")}")
  expect(errors, catalog.include?("filename: \"#{model.fetch("filename")}\""), "model catalog missing filename #{model.fetch("filename")}")
  expect(errors, catalog.include?("expectedSHA1: \"#{model.fetch("sha1")}\""), "model catalog missing checksum #{model.fetch("sha1")}")
end
installer = File.read(File.join(root, "scripts/install_model.sh"))
expect(errors, installer.include?("model_sources.whisper.revision"), "install_model.sh does not read the Whisper model revision from provenance")
expect(errors, installer.include?("resolve/$WHISPER_MODEL_REV/"), "install_model.sh does not use its pinned Whisper model revision")
expect(errors, !installer.include?("resolve/main/"), "install_model.sh still uses a mutable Whisper model URL")

bootstrap = File.read(File.join(root, "scripts/bootstrap_whisper_cpp.sh"))
expect(errors, bootstrap.include?("bundled_runtimes.0.revision"), "bootstrap_whisper_cpp.sh does not read the runtime revision from provenance")
expect(errors, bootstrap.include?("Refusing to clone or build whisper.cpp from an unpinned source."), "bootstrap_whisper_cpp.sh does not fail closed without runtime provenance")
expect(errors, !bootstrap.include?("cloning upstream HEAD"), "bootstrap_whisper_cpp.sh still falls back to mutable upstream HEAD")

llama_bootstrap = File.read(File.join(root, "scripts/bootstrap_llama_cpp.sh"))
expect(errors, manifest.fetch("bundled_runtimes").any? { |runtime| runtime.fetch("name") == "llama.cpp" }, "llama.cpp runtime missing from provenance")
expect(errors, llama_bootstrap.include?("Refusing to clone or build llama.cpp from an unpinned source."), "bootstrap_llama_cpp.sh does not fail closed without runtime provenance")
expect(errors, llama_bootstrap.include?("-DLLAMA_OPENSSL=OFF"), "bootstrap_llama_cpp.sh must build the helper without HTTPS model downloads")
expect(errors, llama_bootstrap.include?("-DLLAMA_BUILD_UI=OFF") && llama_bootstrap.include?("-DLLAMA_USE_PREBUILT_UI=OFF"), "bootstrap_llama_cpp.sh must build llama-server without a web UI or a UI download")
expect(errors, llama_bootstrap.include?("TARGETS=(llama-completion llama-server llama-mtmd-cli)"), "bootstrap_llama_cpp.sh must build llama-server and llama-mtmd-cli next to llama-completion")
llama_runtime = manifest.fetch("bundled_runtimes").find { |runtime| runtime.fetch("name") == "llama.cpp" }
llama_artifacts = llama_runtime ? llama_runtime.fetch("artifacts").map { |artifact| File.basename(artifact.fetch("path")) } : []
expect(errors, llama_artifacts == ["llama-completion", "llama-server", "llama-mtmd-cli"], "llama.cpp provenance must list llama-completion, llama-server and llama-mtmd-cli")
# QWEN3-ASR: the speech model pins in provenance match the Swift catalog.
qwen_source = File.read(File.join(root, "Sources/YappYapp/Qwen3ASR.swift"))
qwen_models = manifest.fetch("model_sources").fetch("qwen3_asr").fetch("models")
expect(errors, qwen_models.map { |model| model.fetch("id") } == ["qwen3asr-0.6b", "qwen3asr-1.7b"], "provenance must list both Qwen3-ASR models")
qwen_models.each do |model|
  expect(errors, qwen_source.include?("\"#{model.fetch("repo")}\""), "Qwen3ASR.swift missing repo #{model.fetch("repo")}")
  expect(errors, qwen_source.include?("\"#{model.fetch("revision")}\""), "Qwen3ASR.swift missing revision #{model.fetch("revision")}")
  model.fetch("files").each do |file|
    expect(errors, qwen_source.include?("\"#{file.fetch("filename")}\""), "Qwen3ASR.swift missing file #{file.fetch("filename")}")
    expect(errors, qwen_source.include?("sha256: \"#{file.fetch("sha256")}\""), "Qwen3ASR.swift missing SHA-256 for #{file.fetch("filename")}")
    size = file.fetch("size").to_s.reverse.scan(/\d{1,3}/).join("_").reverse
    expect(errors, qwen_source.include?("size: #{size})"), "Qwen3ASR.swift size drifted for #{file.fetch("filename")}")
  end
end
expect(errors, llama_bootstrap.include?("-DGGML_METAL_EMBED_LIBRARY=ON") && llama_bootstrap.include?("-DBUILD_SHARED_LIBS=OFF"), "bootstrap_llama_cpp.sh must build a static Metal runtime")

notices = File.read(File.join(root, "THIRD_PARTY_NOTICES.md"))
normalized_notices = notices.downcase.gsub(/[^a-z0-9]/, "")
manifest.fetch("swift_package_dependencies").each do |dep|
  source = dep.fetch("source").sub(/\.git\z/, "")
  normalized_license = dep.fetch("license").downcase.gsub(/[^a-z0-9]/, "")
  expect(errors, notices.include?(source), "third-party notices missing dependency source #{source}")
  expect(errors, normalized_notices.include?(normalized_license), "third-party notices missing dependency license #{dep.fetch("identity")}")
end
manifest.fetch("bundled_runtimes").each do |runtime|
  normalized_license = runtime.fetch("license").downcase.gsub(/[^a-z0-9]/, "")
  expect(errors, notices.include?(runtime.fetch("source")), "third-party notices missing runtime source #{runtime.fetch("source")}")
  expect(errors, normalized_notices.include?(normalized_license), "third-party notices missing runtime license #{runtime.fetch("name")}")
end
parakeet_source = [
  "Sources/YappYapp/ModelDownloadManager.swift",
  "Sources/YappYapp/ParakeetModelDistribution.swift"
].map { |path| File.read(File.join(root, path)) }.join("\n")
parakeet_runtime_source = File.read(File.join(root, "Sources/YappYapp/ParakeetTranscriber.swift"))
app_delegate_source = File.read(File.join(root, "Sources/YappYapp/AppDelegate.swift"))
parakeet_repositories = manifest.fetch("model_sources").fetch("parakeet").fetch("repositories")
expected_source_repo_cases = {
  "ultra" => "parakeetUltra",
  "v3" => "parakeetV3",
  "v2" => "parakeetV2",
  "tdtCtc110m" => "parakeetTdtCtc110m",
  "tdtJa" => "parakeetJa"
}
parakeet_repositories.each do |entry|
  variant = entry.fetch("variant")
  repo = entry.fetch("repo")
  revision = entry.fetch("revision")
  expect(errors, revision.match?(/\A[0-9a-f]{40}\z/), "Parakeet #{variant} revision must be a 40-char git SHA")
  expect(errors, notices.include?(repo), "third-party notices missing Parakeet repo #{repo}")
  expect(errors, notices.include?(revision), "third-party notices missing Parakeet revision #{revision}")

  source_repo_case = expected_source_repo_cases[variant]
  expect(errors, !source_repo_case.nil?, "unknown Parakeet provenance variant #{variant}")
  next unless source_repo_case

  variant_marker = variant == "v3" ? "default:" : "case \"#{variant}\":"
  assignment_pattern = /#{Regexp.escape(variant_marker)}.*?repo = \.#{Regexp.escape(source_repo_case)}.*?revision = "#{Regexp.escape(revision)}"/m
  expect(errors, parakeet_source.match?(assignment_pattern), "Parakeet #{variant} repo/revision does not match ModelDownloadManager.parakeetDownloadPlan")
end
expect(errors, parakeet_runtime_source.include?("ModelHub.offlineMode = true"), "FluidAudio must remain offline for verified Parakeet loading")
expect(errors, parakeet_runtime_source.include?("guard downloadsAllowed else"), "YappYapp Parakeet downloader is not gated by allowModelDownloads")
expect(errors, parakeet_runtime_source.include?("try await ModelDownloadManager.downloadParakeet"), "Parakeet network downloads do not route through ModelDownloadManager")
expect(errors, parakeet_runtime_source.include?("guard ModelDownloadManager.isVerifiedParakeetCache(variant: variant) else"), "Parakeet loading does not require a verified cache manifest")
expect(errors, parakeet_runtime_source.include?("let models = try await AsrModels.load("), "FluidAudio Parakeet inference is not using the local-only load path")
expect(errors, !parakeet_runtime_source.match?(/AsrModels\.(?:download|downloadAndLoad)/), "FluidAudio download API is reachable from ParakeetTranscriber")
# YA-01 moved this guard: recording is blocked by RecordingPrerequisite, and
# transcription throws when the verified cache (isInstalled) is missing.
expect(errors, app_delegate_source.include?("let isCached = option?.isInstalled ?? false") && app_delegate_source.include?("if !isCached {"), "recording does not reject an unverified Parakeet cache")
expect(errors, File.read(File.join(root, "Sources/YappYapp/FirstRunReadiness.swift")).include?("guard selectedModelInstalled else"), "recording does not require the selected model to be installed")
expect(errors, parakeet_source.include?("private static let huggingFaceOrigin = \"https://huggingface.co\""), "Parakeet downloader is not fixed to the Hugging Face origin")
expect(errors, !parakeet_source.match?(/ModelRegistry\.(?:baseURL|apiModels)|REGISTRY_URL|MODEL_REGISTRY_URL/), "Parakeet downloader uses an environment-controlled model registry")
expect(errors, !parakeet_source.match?(/Authorization|Bearer\s|HF_TOKEN|HUGGING_FACE_HUB_TOKEN|HUGGINGFACE_TOKEN/), "public Parakeet downloader reads or attaches ambient credentials")

llm_cleanup = manifest.fetch("model_sources").fetch("llm_cleanup")
llm_source = File.read(File.join(root, "Sources/YappYapp/LLMCleaner.swift"))
expect(errors, notices.include?(llm_cleanup.fetch("source")), "third-party notices missing Qwen cleanup model source")
expect(errors, normalized_notices.include?(llm_cleanup.fetch("license").downcase.gsub(/[^a-z0-9]/, "")), "third-party notices missing Qwen cleanup model license")
expect(errors, llm_source.include?("let LLMCleanerPinnedRevision = \"#{llm_cleanup.fetch("revision")}\""), "LLM cleanup revision does not match provenance")
expect(errors, llm_source.include?("let LLMCleanerPinnedSHA1 = \"#{llm_cleanup.fetch("sha1")}\""), "LLM cleanup checksum does not match provenance")
expect(errors, llm_source.include?(llm_cleanup.fetch("filename")), "LLM cleanup filename does not match provenance")

# TRANSLATION (round 2): every pinned translation model matches the Swift
# catalog and is named in the third-party notices.
translation_source = File.read(File.join(root, "Sources/YappYapp/Translation.swift"))
manifest.fetch("model_sources").fetch("translation").fetch("models").each do |model|
  expect(errors, notices.include?(model.fetch("source")), "third-party notices missing #{model.fetch("repo")}")
  expect(errors, translation_source.include?("\"#{model.fetch("revision")}\""), "#{model.fetch("id")} revision does not match provenance")
  expect(errors, translation_source.include?("\"#{model.fetch("sha256")}\""), "#{model.fetch("id")} SHA-256 does not match provenance")
  expect(errors, translation_source.include?(model.fetch("filename")), "#{model.fetch("id")} filename does not match provenance")
  expect(errors, translation_source.gsub("_", "").include?("sizeBytes: #{model.fetch("size")}"), "#{model.fetch("id")} size does not match provenance")
end

hf_cards = manifest.fetch("huggingface_model_cards")
expect(errors, hf_cards.fetch("checked_at").match?(/\A\d{4}-\d{2}-\d{2}\z/), "huggingface_model_cards.checked_at must be YYYY-MM-DD")
hf_cards_by_repo = hf_cards.fetch("models").each_with_object({}) { |model, acc| acc[model.fetch("repo")] = model }
whisper_card = hf_cards_by_repo["ggerganov/whisper.cpp"]
expect(errors, !whisper_card.nil?, "Whisper provenance is missing its Hugging Face model-card record")
expect(errors, whisper_card && whisper_card.fetch("revision") == whisper_source.fetch("revision"), "Whisper download revision does not match Hugging Face model-card provenance")
parakeet_repositories.each do |entry|
  card = hf_cards_by_repo[entry.fetch("repo")]
  expect(errors, !card.nil?, "Parakeet provenance repo missing Hugging Face model-card record: #{entry.fetch("repo")}")
  expect(errors, card && card.fetch("revision") == entry.fetch("revision"), "Parakeet #{entry.fetch("variant")} pinned revision does not match Hugging Face model-card provenance")
end
hf_cards.fetch("models").each do |model|
  repo = model.fetch("repo")
  # QWEN3-ASR: a conversion that declares no license of its own (expected
  # license "") must name the base model card that carries it.
  license = model.fetch("expected_license")
  base_card = hf_cards.fetch("models").find { |card| card.fetch("repo") == model["license_from"] }
  license_ok = license.is_a?(String) && (!license.empty? || (base_card && !base_card.fetch("expected_license").empty?))
  expect(errors, license_ok, "#{repo} missing expected_license")
  expect(errors, model.fetch("revision").match?(/\A[0-9a-f]{40}\z/), "#{repo} revision must be a 40-char git SHA")
  expect(errors, model.fetch("expected_gated") == false, "#{repo} should be public/non-gated in this release")
  expect(errors, model.fetch("expected_private") == false, "#{repo} should be public in this release")
  expect(errors, model.fetch("url").start_with?("https://huggingface.co/"), "#{repo} url should point to Hugging Face")
end

if errors.empty?
  puts "Release provenance verified."
else
  errors.each { |error| warn "FAIL #{error}" }
  exit 1
end
RUBY
