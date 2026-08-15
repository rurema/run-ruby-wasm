# frozen_string_literal: true

# rurema/run-ruby-wasm の設定値をまとめたモジュール。
# build.rb・test/test_build.rb の両方から require される、副作用のない定数集。
module RunRubyWasm
  module Config
    # @ruby/*-wasm-wasi npm パッケージの dist-tag。
    # docs.ruby-lang.org 側 (bitclust theme/default/js/run-worker.js) が読み込む
    # ローダーのバージョンと揃えること。
    NPM_VERSION = "2.9.3-2.9.4"

    # 対応する Ruby シリーズ (X.Y) → ruby/ruby リポジトリのブランチ名。
    # gems/bundled_gems の取得元になる。
    VERSIONS = {
      "3.2" => "ruby_3_2",
      "3.3" => "ruby_3_3",
      "3.4" => "ruby_3_4",
      "4.0" => "ruby_4_0"
    }.freeze

    # ベースになる ruby+stdlib.wasm (上流 ruby/ruby.wasm の npm 配布物) の URL。
    def self.base_wasm_url(series)
      "https://cdn.jsdelivr.net/npm/@ruby/#{series}-wasm-wasi@#{NPM_VERSION}/dist/ruby+stdlib.wasm"
    end

    # 対象シリーズの gems/bundled_gems の取得元 URL。
    def self.bundled_gems_url(series)
      "https://raw.githubusercontent.com/ruby/ruby/#{VERSIONS.fetch(series)}/gems/bundled_gems"
    end

    # 提供しない (できない) gem と、その理由。
    # C 拡張・OS のネットワーク/端末機能への依存・Windows 専用など、
    # ブラウザ内で動く ruby.wasm では原理的に動かせないもの。
    EXCLUDED_GEMS = {
      "bigdecimal" => "C 拡張のため",
      "debug" => "C 拡張のため",
      "rbs" => "C 拡張のため",
      "nkf" => "C 拡張のため",
      "syslog" => "C 拡張のため",
      "fiddle" => "C 拡張 (dlopen) のため",
      "readline" => "reline (io/console) 依存のため",
      "reline" => "io/console 依存のため",
      "irb" => "io/console 依存のため",
      "win32ole" => "Windows 専用のため",
      "typeprof" => "rbs 依存のため",
      "repl_type_completor" => "rbs/prism 依存のため",
      "drb" => "socket 依存のため",
      "rinda" => "drb/socket 依存のため",
      "resolv-replace" => "socket 依存のため",
      "net-ftp" => "socket 依存のため",
      "net-imap" => "socket 依存のため",
      "net-pop" => "socket 依存のため",
      "net-smtp" => "socket 依存のため"
    }.freeze

    # require するフィーチャー名が gem 名と異なるものの例外表。
    # 既定 (このハッシュに無い場合) は gem 名の "-" を "/" に置換したもの
    # (例: net-ftp -> net/ftp、mutex_m -> mutex_m のように "-" が無ければ無変換)。
    REQUIRE_NAMES = {
      "racc" => "racc/parser",
      # rexml の正規の require は "rexml/document"。既定の "-"→"/" 置換だと
      # "rexml" になってしまうが、一部バージョンではそのファイルが存在しないため
      # 明示的に上書きする。
      "rexml" => "rexml/document"
    }.freeze

    # gem 名から probe/verify で実際に require するフィーチャー名を求める。
    def self.require_name_for(gem_name)
      REQUIRE_NAMES.fetch(gem_name) { gem_name.tr("-", "/") }
    end

    # ruby.wasm では提供できない feature と、スタブメッセージに埋め込む理由句。
    # 実際にスタブを生成するかどうかは probe の結果 (loaderror のときだけ) で
    # 決まる。ここに載っているだけでは足さない。
    STUB_FEATURES = {
      "socket" => "OS のネットワーク機能を使うため",
      "net/ftp" => "OS のネットワーク機能を使うため",
      "net/imap" => "OS のネットワーク機能を使うため",
      "net/pop" => "OS のネットワーク機能を使うため",
      "net/smtp" => "OS のネットワーク機能を使うため",
      "resolv-replace" => "OS のネットワーク機能を使うため",
      "drb" => "ネットワーク機能 (socket) を使うため",
      "drb/drb" => "ネットワーク機能 (socket) を使うため",
      "rinda/rinda" => "ネットワーク機能 (socket) を使うため",
      "rinda/tuplespace" => "ネットワーク機能 (socket) を使うため",
      "io/console" => "端末 (コンソール) 機能を使うため",
      "io/wait" => "端末 (コンソール) 機能を使うため",
      "io/nonblock" => "端末 (コンソール) 機能を使うため",
      "pty" => "端末 (コンソール) 機能を使うため",
      "readline" => "端末 (コンソール) 機能を使うため",
      "reline" => "端末 (コンソール) 機能を使うため",
      "irb" => "端末 (コンソール) 機能を使うため",
      "debug" => "デバッガが OS の機能を使うため",
      "bigdecimal" => "C 拡張のため",
      "nkf" => "C 拡張のため",
      "syslog" => "C 拡張のため",
      "fiddle" => "C 拡張のため",
      "win32ole" => "Windows 専用のため",
      "rbs" => "ruby.wasm に組み込まれていないため",
      "typeprof" => "ruby.wasm に組み込まれていないため"
    }.freeze
  end
end
