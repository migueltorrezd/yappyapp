#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ruby <<'RUBY'
require "pathname"
require "uri"

root = Pathname.pwd
docs = []
docs.concat(Dir.glob("*.md"))
docs.concat(Dir.glob("docs/*.md"))
docs.concat(Dir.glob(".github/**/*.md"))
docs.sort!

skip_schemes = /\A(?:https?:|mailto:|tel:|file:|x-apple\.systempreferences:)/i
errors = []
checked = 0

docs.each do |relative_path|
  text = File.read(relative_path)
  base = Pathname(relative_path).dirname

  text.scan(/(?<!!)\[[^\]\n]+\]\(([^)\s]+)(?:\s+["'][^"']*["'])?\)/) do |match|
    target = match.first.to_s.strip
    next if target.empty?
    next if target.start_with?("#")
    next if target.match?(skip_schemes)

    target = target[1..-2] if target.start_with?("<") && target.end_with?(">")
    target_without_anchor = target.split("#", 2).first
    target_without_query = target_without_anchor.split("?", 2).first
    next if target_without_query.empty?

    begin
      decoded = URI::DEFAULT_PARSER.unescape(target_without_query)
    rescue ArgumentError
      decoded = target_without_query
    end

    resolved = (base + decoded).cleanpath
    checked += 1

    unless (root + resolved).exist?
      errors << "#{relative_path}: broken local link #{target.inspect} -> #{resolved}"
    end
  end
end

if errors.empty?
  puts "Documentation links verified: #{checked} local links across #{docs.length} Markdown files."
else
  warn "Documentation link check failed:"
  errors.each { |error| warn "  - #{error}" }
  exit 1
end
RUBY
