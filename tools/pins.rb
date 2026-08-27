#!/usr/bin/env ruby
# frozen_string_literal: true

# pins.rb — read recipe.yml's `tools:` block (the repo's toolchain pin
# SSOT) and emit KEY=VALUE lines for $GITHUB_ENV. The workflow carries NO
# version or digest literals — every value flows from the recipe.
#
#   ruby tools/pins.rb <tool-platform> [--env]
#   ruby tools/pins.rb --release-only
#
# <tool-platform> is the tebako release asset platform (macos-arm64,
# linux-gnu-x86_64, windows-ucrt64). --release-only emits just
# TEBAKO_RELEASE/TEBAKO_VERSION/PKG_NAME/PKG_VERSION. Unknown platform /
# missing pin is a named error, never a guess (spec 00 §9).

require "yaml"

def die(msg)
  warn "pins.rb: #{msg}"
  exit 64
end

root = File.expand_path("..", __dir__)
recipe = YAML.load_file(File.join(root, "recipe.yml"))
tools = recipe.fetch("tools")
release = tools.fetch("release")
version = release.sub(/\Av/, "")
die "recipe.yml tools.sha256 missing" unless tools["sha256"].is_a?(Hash)

pairs = {
  "TEBAKO_RELEASE" => release,
  "TEBAKO_VERSION" => version,
  "PKG_NAME" => recipe.fetch("name"),
  "PKG_VERSION" => recipe.dig("upstream", "version") ||
                   die("recipe.yml upstream.version missing"),
}

unless ARGV.include?("--release-only")
  platform = ARGV[0] or die "usage: pins.rb <tool-platform> [--env] | pins.rb --release-only"
  exe = platform.start_with?("windows") ? ".exe" : ""
  { "tebako" => "TEBAKO", "tebako-shim" => "SHIM", "tfs" => "TFS" }.each do |tool, key|
    sha = tools.dig("sha256", tool, platform) or
      die "recipe.yml: no tools.sha256.#{tool}.#{platform} pin"
    pairs["#{key}_ASSET"] = "#{tool}-#{version}-#{platform}#{exe}"
    pairs["#{key}_SHA256"] = sha
  end
end

if ARGV.include?("--env") || ARGV.include?("--release-only")
  pairs.each { |k, v| puts "#{k}=#{v}" }
else
  pairs.each { |k, v| puts "export #{k}=#{v}" }
end
