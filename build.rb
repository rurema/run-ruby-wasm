#!/usr/bin/env ruby
# frozen_string_literal: true

# rurema/run-ruby-wasm のビルドスクリプト。
#
#   ruby build.rb            # config.rb の VERSIONS 全シリーズをビルド
#   ruby build.rb 3.4 4.0    # 指定したシリーズだけビルド
#
# シリーズごとに以下を行う (詳細は README.md の「仕組み」を参照):
#   1. 上流の ruby+stdlib.wasm をダウンロード (tmp/ にキャッシュ)
#   2. gems/bundled_gems を取得してパース
#   3. 提供できない gem (EXCLUDED_GEMS) を除外
#   4. probe.mjs でベース wasm に何が既にあるか調べる
#   5. 無い (LoadError になる) ものだけ gem install → overlay にコピー
#   6. 無い (LoadError になる) スタブ対象 feature だけスタブを生成
#   7. rbwasm pack で一度だけ焼き込む
#   8. manifest.json を書き出す
#   9. verify.mjs で焼き込んだ wasm を検証 (失敗したらビルド全体を失敗させる)
#
# 「probe して足りないものだけ足す」自己適応型: 上流が対応した項目は自動的に
# 何も足さなくなる。C 拡張・stdlib 純正コード以外は使わない (実行時外部 gem 無し)。
require_relative "config"
require "net/http"
require "uri"
require "json"
require "digest"
require "fileutils"
require "open3"

module RunRubyWasm
  ROOT_DIR = File.expand_path(__dir__)
  TMP_DIR = File.join(ROOT_DIR, "tmp")
  DIST_DIR = File.join(ROOT_DIR, "dist")
  JS_DIR = File.join(ROOT_DIR, "js")

  # gem の lib/ 配下からパッケージ時に取り除くファイル (ホストでコンパイルされた
  # ネイティブ拡張。racc は `extconf.rb` 経由で cparse.so をビルドすることがある
  # ため、確実に取り除く)。
  NATIVE_EXT_PATTERN = /\.(so|bundle|dll)\z/.freeze

  module_function

  # ===== 純粋関数 (ネットワーク・ファイル I/O なし) =====================

  # gems/bundled_gems のテキストをパースして [[name, version], ...] を返す。
  # コメント行 (# 始まり) と空行は無視し、3 列目以降 (repository-url や
  # revision) は捨てる。
  def parse_bundled_gems(text)
    text.each_line.filter_map do |line|
      line = line.strip
      next if line.empty? || line.start_with?("#")

      name, version, = line.split(/\s+/)
      [name, version]
    end
  end

  # gem 一覧を [candidates, excluded] に分割する。
  # candidates: EXCLUDED_GEMS に無いもの ([[name, version], ...] のまま)
  # excluded:   EXCLUDED_GEMS にあるもの ({name => reason})
  def partition_gems(gems)
    candidates = []
    excluded = {}
    gems.each do |name, version|
      reason = Config::EXCLUDED_GEMS[name]
      if reason
        excluded[name] = reason
      else
        candidates << [name, version]
      end
    end
    [candidates, excluded]
  end

  # LoadError 互換のスタブソースを生成する。
  # - LoadError のサブクラスではなく LoadError そのものを raise するので
  #   `rescue LoadError` によるフィーチャー検出パターンが壊れない。
  # - @path を設定するので `e.path` が本物の LoadError と同じように振る舞う。
  def stub_source(feature, reason)
    <<~RUBY
      # rurema/run-ruby-wasm が生成したスタブ (docs.ruby-lang.org の RUN ボタン用)
      err = LoadError.new(
        "#{feature} は#{reason}、ブラウザ内で実行される ruby.wasm では利用できません。" \\
        "このサンプルはお手元の Ruby で実行してください (cannot load such file -- #{feature})"
      )
      err.instance_variable_set(:@path, "#{feature}")
      raise err
    RUBY
  end

  # probe 結果 (feature => "ok" | "loaderror" | "error:<Class>") から、
  # 追加すべき gem (gems_to_add) と、既に (ベース wasm に) 存在するので
  # 追加不要な gem 名 (gems_skipped_present) を決める。
  # probe 結果は require_name_for で変換したフィーチャー名をキーにして引く。
  def decide_gems(candidates, probe_results)
    gems_to_add = []
    gems_skipped_present = []
    candidates.each do |name, version|
      feature = Config.require_name_for(name)
      case probe_results[feature]
      when "ok"
        gems_skipped_present << name
      else
        # "loaderror" はもちろん、想定外の結果 (probe 未実施 / error:<Class>) も
        # 安全側 (追加するほうが安全 = 上書きしてでも足りるようにする) に倒す。
        gems_to_add << [name, version]
      end
    end
    [gems_to_add, gems_skipped_present]
  end

  # probe 結果から、スタブを生成すべき feature (stubs) と、スタブ無しで
  # ネイティブに動く feature (native_ok) を決める。
  # "ok" で無いもの全部をスタブする、ではない点に注意: "error:<Class>" のような
  # 想定外の結果は「本当に無いのか」が確証できないので、あえて何もしない
  # (スタブで隠さない・native_ok として太鼓判も押さない)。
  #
  # "shadowed:..." (probe.mjs 参照) も意図的にここで弾く: 一部のベース wasm
  # (3.2 系で確認) は除外対象の gem (net-ftp・rbs・reline など) を実体として
  # 既にインストール済みだが、その依存 (socket・io-console 等) が無く
  # 壊れている。この場合 require は LoadError にはなるが、$LOAD_PATH 上で
  # 実体のファイルが site_ruby (スタブの置き場所) より先に見つかるため、
  # スタブを置いても絶対に読まれない。読まれないスタブで「親切なメッセージを
  # 出す」と嘘をつくよりは、何もしない (元からの LoadError のままにする) 方が
  # 誠実なので、ここでは stubs にも native_ok にも入れない。
  def decide_stubs(probe_results)
    stubs = {}
    native_ok = []
    Config::STUB_FEATURES.each do |feature, reason|
      case probe_results[feature]
      when "ok"
        native_ok << feature
      when "loaderror"
        stubs[feature] = reason
      end
      # それ以外 (未探査 / shadowed:... / error:<Class>) はどちらにも入れない。
    end
    [stubs, native_ok]
  end

  # STUB_FEATURES のうち、probe が "shadowed:..." を返したもの (スタブを
  # 置いても読まれない、というだけで実際は依然として LoadError になる)。
  # manifest に記録して透明性を確保するための補助情報。
  def shadowed_stub_candidates(probe_results)
    Config::STUB_FEATURES.each_key.filter_map do |feature|
      status = probe_results[feature]
      [feature, status] if status.is_a?(String) && status.start_with?("shadowed:")
    end.to_h
  end

  # gem 名 => 相対パス配列 のハッシュから、2 つ以上の gem で衝突している
  # 相対パスを検出する。{相対パス => [gem名, gem名, ...]} を返す
  # (衝突が無ければ空ハッシュ)。
  def detect_path_collisions(gem_files_by_name)
    owners = Hash.new { |h, k| h[k] = [] }
    gem_files_by_name.each do |name, paths|
      paths.each { |path| owners[path] << name }
    end
    owners.select { |_path, names| names.uniq.size > 1 }
           .transform_values(&:uniq)
  end

  # ===== I/O を伴うヘルパー ==============================================

  def log(msg)
    warn "[run-ruby-wasm] #{msg}"
  end

  # URL をキャッシュキーにして tmp/downloads/ にダウンロードする。
  # 既にファイルがあれば再ダウンロードしない。戻り値はローカルパス。
  def download_cached(url)
    FileUtils.mkdir_p(File.join(TMP_DIR, "downloads"))
    digest = Digest::SHA256.hexdigest(url)[0, 16]
    basename = File.basename(URI.parse(url).path)
    dest = File.join(TMP_DIR, "downloads", "#{digest}-#{basename}")
    if File.exist?(dest)
      log "cache hit: #{url} -> #{dest}"
      return dest
    end

    log "downloading #{url}"
    body = http_get(url)
    File.binwrite(dest, body)
    dest
  end

  def http_get(url, redirects_left = 5)
    uri = URI.parse(url)
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 30, read_timeout: 120) do |http|
      response = http.get(uri.request_uri, { "User-Agent" => "rurema-run-ruby-wasm" })
      case response
      when Net::HTTPSuccess
        response.body
      when Net::HTTPRedirection
        raise "too many redirects for #{url}" if redirects_left <= 0

        http_get(response["location"], redirects_left - 1)
      else
        raise "GET #{url} failed: #{response.code} #{response.message}"
      end
    end
  end

  def sha256_file(path)
    Digest::SHA256.file(path).hexdigest
  end

  # node js/probe.mjs <wasm> <features.json> を実行して結果を得る。
  # 戻り値: { "results" => {feature => status}, "load_path" => [...] }
  def probe(wasm_path, features)
    request_path = File.join(TMP_DIR, "probe-request-#{Digest::SHA256.hexdigest(features.join(","))[0, 8]}.json")
    File.write(request_path, JSON.generate({ features: features.uniq }))
    stdout = run_node(File.join(JS_DIR, "probe.mjs"), wasm_path, request_path)
    JSON.parse(stdout)
  end

  def run_node(*args)
    stdout, stderr, status = Open3.capture3("node", *args)
    warn stderr unless stderr.strip.empty?
    raise "node #{args.join(' ')} failed (exit #{status.exitstatus})" unless status.success?

    stdout
  end

  # `gem install -N --install-dir <dir> name -v version` を実行する。
  def gem_install(install_dir, name, version)
    FileUtils.mkdir_p(install_dir)
    stdout, stderr, status = Open3.capture3(
      "gem", "install", "-N", "--install-dir", install_dir, name, "-v", version
    )
    raise "gem install #{name} -v #{version} failed:\n#{stdout}\n#{stderr}" unless status.success?

    log "gem install #{name} -v #{version}: ok"
  end

  # gemhome (gem install --install-dir の中身) から、指定した gem の
  # lib/ 配下のファイル一覧を相対パスで返す (ネイティブ拡張は除く)。
  def gem_lib_files(gemhome, name, version)
    lib_dir = File.join(gemhome, "gems", "#{name}-#{version}", "lib")
    return [] unless Dir.exist?(lib_dir)

    Dir.glob("**/*", base: lib_dir).select { |p| File.file?(File.join(lib_dir, p)) }
       .reject { |p| p.match?(NATIVE_EXT_PATTERN) }
  end

  # gem の lib/ 配下を overlay ディレクトリにフラットにコピーする。
  def copy_gem_lib(gemhome, name, version, overlay_gems_dir, relative_paths)
    lib_dir = File.join(gemhome, "gems", "#{name}-#{version}", "lib")
    relative_paths.each do |relative_path|
      src = File.join(lib_dir, relative_path)
      dst = File.join(overlay_gems_dir, relative_path)
      FileUtils.mkdir_p(File.dirname(dst))
      FileUtils.cp(src, dst)
    end
  end

  def write_stub(overlay_stubs_dir, feature, reason)
    dst = File.join(overlay_stubs_dir, "#{feature}.rb")
    FileUtils.mkdir_p(File.dirname(dst))
    File.write(dst, stub_source(feature, reason))
  end

  def rbwasm_pack(base_wasm, overlay_gems_dir, overlay_stubs_dir, site_ruby_versioned, output_path)
    FileUtils.mkdir_p(File.dirname(output_path))
    args = ["rbwasm", "pack", base_wasm]
    args += ["--dir", "#{overlay_gems_dir}::/usr/local/lib/ruby/site_ruby/#{site_ruby_versioned}"]
    args += ["--dir", "#{overlay_stubs_dir}::/usr/local/lib/ruby/site_ruby"]
    args += ["-o", output_path]
    stdout, stderr, status = Open3.capture3(*args)
    raise "rbwasm pack failed:\n#{stdout}\n#{stderr}" unless status.success?

    log "rbwasm pack -> #{output_path}"
  end

  # ===== シリーズ 1 個分のビルド =========================================

  def build_series(series)
    log "==== building ruby-#{series}.wasm ===="
    FileUtils.mkdir_p([TMP_DIR, DIST_DIR])

    # 1. ベース wasm のダウンロード
    base_url = Config.base_wasm_url(series)
    base_wasm = download_cached(base_url)
    base_sha256 = sha256_file(base_wasm)
    base_bytes = File.size(base_wasm)
    log "base wasm: #{base_wasm} (#{base_bytes} bytes, sha256=#{base_sha256})"

    # 2. bundled_gems の取得とパース
    bundled_gems_url = Config.bundled_gems_url(series)
    bundled_gems_text = http_get(bundled_gems_url)
    all_gems = parse_bundled_gems(bundled_gems_text)
    log "bundled_gems: #{all_gems.size} entries"

    # 3. 除外の判定
    candidates, gems_excluded = partition_gems(all_gems)
    log "candidates: #{candidates.map(&:first).join(', ')}"
    log "excluded: #{gems_excluded.keys.join(', ')}"

    # 4. probe パス1 (候補 gem のフィーチャー + STUB_FEATURES の全キー)
    candidate_features = candidates.map { |name, _v| Config.require_name_for(name) }
    stub_candidate_features = Config::STUB_FEATURES.keys
    probe_result = probe(base_wasm, candidate_features + stub_candidate_features)
    probe_results = probe_result.fetch("results")
    load_path = probe_result.fetch("load_path")
    log "load_path: #{load_path.join(', ')}"

    # 5. 決定
    gems_to_add, gems_skipped_present = decide_gems(candidates, probe_results)
    stubs, native_ok = decide_stubs(probe_results)
    stub_shadowed = shadowed_stub_candidates(probe_results)
    log "gems_to_add: #{gems_to_add.map(&:first).join(', ')}"
    log "gems_skipped_present: #{gems_skipped_present.join(', ')}"
    log "stubs: #{stubs.keys.join(', ')}"
    log "native_ok: #{native_ok.join(', ')}"
    unless stub_shadowed.empty?
      log "shadowed (already broken in base wasm, stub would be unreachable, left as-is): " \
          "#{stub_shadowed.map { |f, s| "#{f} (#{s})" }.join(', ')}"
    end

    # 6. $LOAD_PATH に site_ruby/<series>.0 があることを確認
    site_ruby_versioned = "#{series}.0"
    expected_path_suffix = "/usr/local/lib/ruby/site_ruby/#{site_ruby_versioned}"
    unless load_path.any? { |p| p.end_with?(expected_path_suffix) }
      raise "expected #{expected_path_suffix} in $LOAD_PATH but got: #{load_path.inspect}"
    end

    # 7. gem install + overlay へコピー (衝突検出込み)
    overlay_dir = File.join(TMP_DIR, "overlay-#{series}")
    overlay_gems_dir = File.join(overlay_dir, "gems")
    overlay_stubs_dir = File.join(overlay_dir, "stubs")
    FileUtils.rm_rf(overlay_dir)
    FileUtils.mkdir_p([overlay_gems_dir, overlay_stubs_dir])

    gemhome = File.join(TMP_DIR, "gemhome-#{series}")
    FileUtils.rm_rf(gemhome)

    gem_files_by_name = {}
    gems_to_add.each do |name, version|
      gem_install(gemhome, name, version)
      gem_files_by_name[name] = gem_lib_files(gemhome, name, version)
    end

    collisions = detect_path_collisions(gem_files_by_name)
    unless collisions.empty?
      raise "gem lib/ path collisions detected: #{collisions.inspect}"
    end

    gems_to_add.each do |name, version|
      copy_gem_lib(gemhome, name, version, overlay_gems_dir, gem_files_by_name.fetch(name))
    end

    # 実際に gem install されたが gems_to_add に無いもの (依存として
    # 自動インストールされたもの) をログに残す (overlay にはコピーしない)。
    if Dir.exist?(File.join(gemhome, "gems"))
      installed_dirnames = Dir.children(File.join(gemhome, "gems"))
      requested_dirnames = gems_to_add.map { |name, version| "#{name}-#{version}" }
      auto_installed = installed_dirnames - requested_dirnames
      log "auto-installed deps (not copied): #{auto_installed.join(', ')}" unless auto_installed.empty?
    end

    # 8. スタブの生成
    stubs.each { |feature, reason| write_stub(overlay_stubs_dir, feature, reason) }

    # 9. rbwasm pack (gems_to_add・stubs が両方空でも出力は必ず作る)
    output_path = File.join(DIST_DIR, "ruby-#{series}.wasm")
    if gems_to_add.empty? && stubs.empty?
      log "no additions for #{series}; copying base wasm as-is"
      FileUtils.cp(base_wasm, output_path)
    else
      rbwasm_pack(base_wasm, overlay_gems_dir, overlay_stubs_dir, site_ruby_versioned, output_path)
    end
    output_bytes = File.size(output_path)

    # 10. manifest
    manifest = {
      "ruby_version" => series,
      "npm_package" => "@ruby/#{series}-wasm-wasi",
      "npm_version" => Config::NPM_VERSION,
      "base_url" => base_url,
      "base_sha256" => base_sha256,
      "base_bytes" => base_bytes,
      "output_bytes" => output_bytes,
      "gems_added" => gems_to_add.to_h,
      "gems_skipped_present" => gems_skipped_present,
      "gems_excluded" => gems_excluded,
      "stubs" => stubs,
      "native_ok" => native_ok,
      # 補助情報 (固定スキーマの 10 項目には無いが、デバッグ・透明性のために
      # 追加): スタブ候補だったが、ベース wasm 側に既に実体 (壊れているが)
      # があってスタブが絶対に読まれないため何もしなかったもの。
      "stub_shadowed" => stub_shadowed
    }
    manifest_path = File.join(DIST_DIR, "ruby-#{series}.manifest.json")
    File.write(manifest_path, JSON.pretty_generate(manifest))
    log "manifest -> #{manifest_path}"

    # 11. verify
    log "verifying #{output_path}"
    verify_stdout, verify_stderr, verify_status = Open3.capture3(
      "node", File.join(JS_DIR, "verify.mjs"), output_path, manifest_path
    )
    puts verify_stdout
    warn verify_stderr unless verify_stderr.strip.empty?
    unless verify_status.success?
      raise "verify failed for ruby-#{series}.wasm (see PASS/FAIL lines above)"
    end

    log "==== ruby-#{series}.wasm OK (#{output_bytes} bytes, delta #{output_bytes - base_bytes} bytes) ===="
    manifest
  end

  def main(argv)
    series_list = argv.empty? ? Config::VERSIONS.keys : argv
    series_list.each do |series|
      unless Config::VERSIONS.key?(series)
        raise "unknown series #{series.inspect}; known: #{Config::VERSIONS.keys.join(', ')}"
      end
    end

    series_list.each { |series| build_series(series) }
    log "all builds succeeded: #{series_list.join(', ')}"
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    RunRubyWasm.main(ARGV)
  rescue StandardError => e
    warn "[run-ruby-wasm] FATAL: #{e.message}"
    warn e.backtrace.take(10).join("\n") if ENV["DEBUG"]
    exit 1
  end
end
