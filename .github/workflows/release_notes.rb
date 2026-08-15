#!/usr/bin/env ruby
# frozen_string_literal: true

# Release ノート生成スクリプト。build.yml の workflow_dispatch (release_tag
# 指定時) からのみ呼ばれる。dist/*.manifest.json を読み、バージョンごとに
# 追加した gem・スタブ・サイズをまとめた Markdown を標準出力に書く。
#
#   ruby .github/workflows/release_notes.rb dist > release-notes.md

require "json"

dist_dir = ARGV.fetch(0, "dist")
manifest_paths = Dir.glob(File.join(dist_dir, "*.manifest.json")).sort

if manifest_paths.empty?
  warn "no manifest.json files found under #{dist_dir}"
  exit 1
end

manifests = manifest_paths.map { |path| JSON.parse(File.read(path)) }
npm_version = manifests.first["npm_version"]

puts "## ruby.wasm (bundled gems 追い焼き版)"
puts
puts "ベース npm パッケージ: `@ruby/<series>-wasm-wasi@#{npm_version}`"
puts

manifests.sort_by { |m| m["ruby_version"] }.each do |manifest|
  series = manifest["ruby_version"]
  gems_added = manifest["gems_added"] || {}
  stubs = manifest["stubs"] || {}
  native_ok = manifest["native_ok"] || []
  base_bytes = manifest["base_bytes"].to_i
  output_bytes = manifest["output_bytes"].to_i
  delta = output_bytes - base_bytes

  puts "### Ruby #{series}"
  puts
  puts "- サイズ: #{output_bytes} bytes (ベース #{base_bytes} bytes、差分 #{delta >= 0 ? '+' : ''}#{delta} bytes)"
  if gems_added.empty?
    puts "- 追加した gem: なし (上流のベースで足りていました)"
  else
    puts "- 追加した gem: #{gems_added.map { |name, version| "#{name} #{version}" }.join(', ')}"
  end
  puts "- スタブ (LoadError で分かりやすいメッセージを出すのみ): #{stubs.keys.join(', ')}" unless stubs.empty?
  puts "- ネイティブに動作 (スタブ不要): #{native_ok.join(', ')}" unless native_ok.empty?
  puts
end

puts "---"
puts
puts "Generated with [Claude Code](https://claude.com/claude-code)"
