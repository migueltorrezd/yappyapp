#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$ROOT_DIR"

ruby <<'RUBY'
require "json"
require "net/http"
require "uri"

manifest = JSON.parse(File.read("docs/RELEASE_PROVENANCE.json"))
cards = manifest.fetch("huggingface_model_cards")
api_base = cards.fetch("api_base")
errors = []

def fetch_json(url)
  uri = URI(url)
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", read_timeout: 20, open_timeout: 10) do |http|
    request = Net::HTTP::Get.new(uri)
    request["User-Agent"] = "YappYapp-release-check"
    http.request(request)
  end

  raise "#{url} returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
  JSON.parse(response.body)
end

cards.fetch("models").each do |expected|
  repo = expected.fetch("repo")
  begin
    data = fetch_json("#{api_base}/#{repo}")
  rescue => error
    errors << "#{repo}: #{error}"
    next
  end

  card = data["cardData"] || {}
  actual_license = card["license"] || ""
  actual_sha = data["sha"] || ""
  actual_gated = data["gated"]
  actual_private = data["private"]

  errors << "#{repo}: license expected #{expected.fetch("expected_license")}, got #{actual_license}" unless actual_license == expected.fetch("expected_license")
  errors << "#{repo}: revision expected #{expected.fetch("revision")}, got #{actual_sha}" unless actual_sha == expected.fetch("revision")
  errors << "#{repo}: gated expected #{expected.fetch("expected_gated")}, got #{actual_gated}" unless actual_gated == expected.fetch("expected_gated")
  errors << "#{repo}: private expected #{expected.fetch("expected_private")}, got #{actual_private}" unless actual_private == expected.fetch("expected_private")

  puts "OK #{repo} license=#{actual_license} sha=#{actual_sha} gated=#{actual_gated} private=#{actual_private}"
end

if errors.empty?
  puts "Hugging Face model metadata verified."
else
  errors.each { |error| warn "FAIL #{error}" }
  warn "Update docs/RELEASE_PROVENANCE.json only after reviewing changed model-card terms."
  exit 1
end
RUBY
