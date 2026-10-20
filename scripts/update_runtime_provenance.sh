#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT_DIR/docs/RELEASE_PROVENANCE.json"

cd "$ROOT_DIR"

[[ -f "$MANIFEST" ]] || { echo "error: missing $MANIFEST" >&2; exit 1; }

# Records the checked-out revision and artifact checksums of every bundled
# runtime (whisper.cpp, and llama.cpp for LLM cleanup) whose vendor checkout
# exists. A runtime without a checkout is reported and left untouched;
# check_provenance.sh still fails a release that is missing one.
ruby -rjson -rdigest <<'RUBY'
root = Dir.pwd
manifest_path = File.join(root, "docs/RELEASE_PROVENANCE.json")
manifest = JSON.parse(File.read(manifest_path))
updated = 0

manifest.fetch("bundled_runtimes").each do |runtime|
  name = runtime.fetch("name")
  checkout = File.join(root, "vendor", name)
  unless File.directory?(File.join(checkout, ".git"))
    warn "skip #{name}: missing vendored checkout at vendor/#{name}"
    next
  end

  revision = IO.popen(["git", "-C", checkout, "rev-parse", "HEAD"], &:read).strip
  raise "could not resolve vendored #{name} revision" unless revision.match?(/\A[0-9a-f]{40}\z/)
  # LLM-CLEANUP: llama.cpp is pinned to a release tag; the tag must keep
  # pointing at the recorded commit, so a moved checkout is an error here.
  if runtime.key?("tag") && runtime.fetch("revision") != revision
    raise "#{name} checkout is at #{revision}, but #{runtime.fetch("tag")} is pinned to #{runtime.fetch("revision")}"
  end
  runtime["revision"] = revision

  runtime.fetch("artifacts").each do |artifact|
    path = File.join(root, artifact.fetch("path"))
    raise "runtime artifact missing: #{artifact.fetch("path")}" unless File.file?(path)
    artifact["sha256"] = Digest::SHA256.file(path).hexdigest
  end

  updated += 1
  puts "Updated #{name} provenance for #{revision}."
  runtime.fetch("artifacts").each do |artifact|
    puts "#{artifact.fetch("sha256")}  #{artifact.fetch("path")}"
  end
end

raise "no vendored runtime checkout found" if updated.zero?
File.write(manifest_path, JSON.pretty_generate(manifest) + "\n")
RUBY
