#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT_DIR"

ruby <<'RUBY'
require "json"

root = Dir.pwd
manifest = JSON.parse(File.read(File.join(root, "docs/RELEASE_PROVENANCE.json")))
catalog = File.read(File.join(root, "Sources/YappYapp/ModelCatalog.swift"))
installer = File.read(File.join(root, "scripts/install_model.sh"))
errors = []

def expect(errors, condition, message)
  errors << message unless condition
end

def shell_name_for(filename)
  filename.sub(/\Aggml-/, "").sub(/\.bin\z/, "")
end

models = manifest.fetch("model_sources").fetch("whisper").fetch("models")
expected_by_filename = models.each_with_object({}) do |model, acc|
  acc[model.fetch("filename")] = {
    "id" => model.fetch("id"),
    "sha1" => model.fetch("sha1"),
    "shell_name" => shell_name_for(model.fetch("filename"))
  }
end

models.each do |model|
  expect(errors, model.fetch("filename").match?(/\Aggml-.+\.bin\z/), "#{model.fetch("id")} filename must be a ggml .bin file")
  expect(errors, model.fetch("sha1").match?(/\A[0-9a-f]{40}\z/), "#{model.fetch("id")} sha1 must be a 40-char lowercase hex digest")
end

catalog_entries = catalog.scan(/ModelOption\((.*?)\n\s*\),?/m).map do |match|
  block = match.first
  filename = block[/filename:\s*"([^"]*)"/, 1]
  next unless filename&.start_with?("ggml-")

  {
    "id" => block[/id:\s*"([^"]+)"/, 1],
    "filename" => filename,
    "sha1" => block[/expectedSHA1:\s*"([0-9a-f]{40})"/, 1]
  }
end.compact

catalog_by_filename = catalog_entries.each_with_object({}) do |entry, acc|
  if acc.key?(entry.fetch("filename"))
    errors << "duplicate Swift ModelCatalog filename: #{entry.fetch("filename")}"
  end
  acc[entry.fetch("filename")] = entry
end

expect(errors, catalog_by_filename.keys == expected_by_filename.keys, "Swift ModelCatalog Whisper filenames drifted from release provenance")
expected_by_filename.each do |filename, expected|
  entry = catalog_by_filename[filename]
  next unless entry

  expect(errors, entry.fetch("id") == expected.fetch("id"), "#{filename} Swift id mismatch: #{entry.fetch("id")} != #{expected.fetch("id")}")
  expect(errors, entry.fetch("sha1") == expected.fetch("sha1"), "#{filename} Swift checksum mismatch: #{entry.fetch("sha1")} != #{expected.fetch("sha1")}")
end

all_models_block = installer[/ALL_MODELS=\((.*?)\)/m, 1]
if all_models_block.nil?
  errors << "scripts/install_model.sh is missing ALL_MODELS"
else
  installer_models = all_models_block.scan(/"([^"]+)"/).flatten
  expected_installer_models = models.map { |model| shell_name_for(model.fetch("filename")) }
  expect(errors, installer_models == expected_installer_models, "install_model.sh ALL_MODELS drifted from release provenance")
end

installer_checksums = installer.scan(/^\s*([A-Za-z0-9.-]+)\)\s+echo\s+"([0-9a-f]{40})"\s+;;/).to_h
expected_installer_checksums = expected_by_filename.values.each_with_object({}) do |model, acc|
  acc[model.fetch("shell_name")] = model.fetch("sha1")
end

expect(errors, installer_checksums.keys.sort == expected_installer_checksums.keys.sort, "install_model.sh expected_sha1 cases drifted from release provenance")
expected_installer_checksums.each do |model_name, expected_sha1|
  actual = installer_checksums[model_name]
  next unless actual

  expect(errors, actual == expected_sha1, "#{model_name} installer checksum mismatch: #{actual} != #{expected_sha1}")
end

if errors.empty?
  puts "Model catalog sync verified: #{models.count} Whisper models."
else
  errors.each { |error| warn "FAIL #{error}" }
  exit 1
end
RUBY
