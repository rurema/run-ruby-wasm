# frozen_string_literal: true

# build.rb の純粋関数 (ネットワーク・ファイル I/O を伴わないロジック) のテスト。
# t_wada 流 TDD: このテストを先に (Red の状態で) 書き、build.rb 側を
# 実装して Green にする。`ruby test/test_build.rb` だけでネットワーク無しに
# 実行できる。
require "test/unit"
require_relative "../build"

class TestParseBundledGems < Test::Unit::TestCase
  def test_parses_name_and_version
    text = <<~TEXT
      minitest            5.25.4  https://github.com/minitest/minitest
      rake                13.2.1  https://github.com/ruby/rake
    TEXT
    assert_equal(
      [["minitest", "5.25.4"], ["rake", "13.2.1"]],
      RunRubyWasm.parse_bundled_gems(text)
    )
  end

  def test_skips_comment_lines
    text = <<~TEXT
      # gem-name version repository-url [revision]
      #
      # - gem-name: gem name to bundle
      csv                 3.3.5   https://github.com/ruby/csv
    TEXT
    assert_equal([["csv", "3.3.5"]], RunRubyWasm.parse_bundled_gems(text))
  end

  def test_skips_blank_lines
    text = "\n\n  \nrexml               3.4.4   https://github.com/ruby/rexml\n\n"
    assert_equal([["rexml", "3.4.4"]], RunRubyWasm.parse_bundled_gems(text))
  end

  def test_ignores_extra_fields_such_as_revision
    text = "net-imap            0.5.15  https://github.com/ruby/net-imap  deadbeef\n"
    assert_equal([["net-imap", "0.5.15"]], RunRubyWasm.parse_bundled_gems(text))
  end

  def test_returns_empty_array_for_empty_text
    assert_equal([], RunRubyWasm.parse_bundled_gems(""))
  end
end

class TestPartitionGems < Test::Unit::TestCase
  def test_separates_excluded_from_candidates
    gems = [
      ["csv", "3.3.5"],
      ["bigdecimal", "3.1.8"],
      ["net-ftp", "0.3.8"],
      ["rexml", "3.4.4"]
    ]
    candidates, excluded = RunRubyWasm.partition_gems(gems)

    assert_equal([["csv", "3.3.5"], ["rexml", "3.4.4"]], candidates)
    assert_equal(
      {
        "bigdecimal" => "C 拡張のため",
        "net-ftp" => "socket 依存のため"
      },
      excluded
    )
  end

  def test_empty_input_yields_empty_output
    candidates, excluded = RunRubyWasm.partition_gems([])
    assert_equal([], candidates)
    assert_equal({}, excluded)
  end

  def test_no_excluded_gems_present
    candidates, excluded = RunRubyWasm.partition_gems([["prime", "0.1.4"]])
    assert_equal([["prime", "0.1.4"]], candidates)
    assert_equal({}, excluded)
  end
end

class TestRequireNameFor < Test::Unit::TestCase
  data(
    "racc maps to racc/parser" => ["racc", "racc/parser"],
    "net-ftp maps to net/ftp (default dash->slash)" => ["net-ftp", "net/ftp"],
    "rexml maps to rexml/document (explicit override)" => ["rexml", "rexml/document"],
    "mutex_m is unchanged (no dash)" => ["mutex_m", "mutex_m"],
    "csv is unchanged (no dash)" => ["csv", "csv"],
    "resolv-replace maps to resolv/replace by default rule" => ["resolv-replace", "resolv/replace"]
  )
  def test_require_name_for(data)
    gem_name, expected = data
    assert_equal(expected, RunRubyWasm::Config.require_name_for(gem_name))
  end
end

class TestStubSource < Test::Unit::TestCase
  def test_message_contains_feature_and_reason_and_standard_tail
    src = RunRubyWasm.stub_source("socket", "OS のネットワーク機能を使うため")

    # テンプレートは "<feature> は<理由句>、..." という形なので、
    # 生成物の文字列にそのまま両方が現れることを検証する。
    assert_include(src, "socket")
    assert_include(src, "OS のネットワーク機能を使うため")
    assert_include(src, "ブラウザ内で実行される ruby.wasm では利用できません")
    assert_include(src, "このサンプルはお手元の Ruby で実行してください")
    assert_include(src, "cannot load such file -- socket")
  end

  def test_path_ivar_is_set_for_e_dot_path_compatibility
    src = RunRubyWasm.stub_source("io/console", "端末 (コンソール) 機能を使うため")
    assert_include(src, ':@path, "io/console"')
  end

  def test_raises_a_loaderror_not_some_other_class
    src = RunRubyWasm.stub_source("bigdecimal", "C 拡張のため")
    assert_include(src, "LoadError.new(")
    assert_include(src, "raise err")
  end

  def test_generated_source_is_syntactically_valid_ruby
    src = RunRubyWasm.stub_source("drb", "ネットワーク機能 (socket) を使うため")
    assert_true(RubyVM::InstructionSequence.compile(src).is_a?(RubyVM::InstructionSequence))
  end

  def test_stub_actually_raises_loaderror_with_expected_path_when_evaluated
    src = RunRubyWasm.stub_source("pty", "端末 (コンソール) 機能を使うため")
    error = assert_raise(LoadError) { eval(src) } # rubocop:disable Security/Eval
    assert_equal("pty", error.path)
    assert_include(error.message, "ruby.wasm では利用できません")
  end
end

class TestDecideGems < Test::Unit::TestCase
  def test_loaderror_means_add_ok_means_skip
    candidates = [["csv", "3.3.5"], ["logger", "1.7.0"]]
    probe_results = {
      "csv" => "loaderror",
      "logger" => "ok"
    }

    gems_to_add, gems_skipped_present = RunRubyWasm.decide_gems(candidates, probe_results)

    assert_equal([["csv", "3.3.5"]], gems_to_add)
    assert_equal(["logger"], gems_skipped_present)
  end

  def test_uses_require_name_mapping_to_look_up_probe_result
    candidates = [["racc", "1.8.1"], ["rexml", "3.4.4"]]
    probe_results = {
      "racc/parser" => "loaderror",
      "rexml/document" => "ok"
    }

    gems_to_add, gems_skipped_present = RunRubyWasm.decide_gems(candidates, probe_results)

    assert_equal([["racc", "1.8.1"]], gems_to_add)
    assert_equal(["rexml"], gems_skipped_present)
  end

  def test_empty_candidates_yields_empty_results
    gems_to_add, gems_skipped_present = RunRubyWasm.decide_gems([], {})
    assert_equal([], gems_to_add)
    assert_equal([], gems_skipped_present)
  end
end

class TestDecideStubs < Test::Unit::TestCase
  def test_loaderror_means_stub_ok_means_native_ok
    probe_results = {
      "socket" => "loaderror",
      "bigdecimal" => "ok"
    }
    stubs, native_ok = RunRubyWasm.decide_stubs(probe_results)

    assert_equal({ "socket" => RunRubyWasm::Config::STUB_FEATURES.fetch("socket") }, stubs)
    assert_equal(["bigdecimal"], native_ok)
  end

  def test_never_stubs_a_feature_that_probed_ok
    # 3.2/3.3 で bigdecimal・nkf がネイティブ組み込みのケース。
    # ここでスタブしてしまうと動くはずのものを壊す。
    probe_results = RunRubyWasm::Config::STUB_FEATURES.keys.to_h { |f| [f, "ok"] }
    stubs, native_ok = RunRubyWasm.decide_stubs(probe_results)

    assert_equal({}, stubs)
    assert_equal(RunRubyWasm::Config::STUB_FEATURES.keys.sort, native_ok.sort)
  end

  def test_unknown_probe_status_is_neither_stubbed_nor_marked_native_ok
    # 想定外の例外 (error:SomeClass) は安全側に倒して何もしない。
    # ok と誤認してスタブを外すことも、loaderror と誤認して不親切な
    # メッセージを覆い隠すこともしない。
    probe_results = { "rbs" => "error:NoMethodError" }
    stubs, native_ok = RunRubyWasm.decide_stubs(probe_results)

    assert_equal({}, stubs)
    assert_equal([], native_ok)
  end

  def test_shadowed_status_is_neither_stubbed_nor_marked_native_ok
    # 3.2 系のベース wasm で実測: net-ftp・rbs・reline などが実体として
    # 既にインストール済みだが壊れている場合、probe.mjs は e.path が
    # feature と一致しないと "shadowed:..." を返す。この場合スタブを
    # 置いても $LOAD_PATH 上で読まれないので、生成してはいけない。
    probe_results = { "net/ftp" => 'shadowed:"socket"', "reline" => "shadowed:nil" }
    stubs, native_ok = RunRubyWasm.decide_stubs(probe_results)

    assert_equal({}, stubs)
    assert_equal([], native_ok)
  end

  def test_features_not_present_in_probe_results_are_ignored
    stubs, native_ok = RunRubyWasm.decide_stubs({})
    assert_equal({}, stubs)
    assert_equal([], native_ok)
  end
end

class TestShadowedStubCandidates < Test::Unit::TestCase
  def test_collects_only_shadowed_statuses
    probe_results = {
      "socket" => "loaderror",
      "bigdecimal" => "ok",
      "net/ftp" => 'shadowed:"socket"',
      "reline" => "shadowed:nil"
    }
    assert_equal(
      { "net/ftp" => 'shadowed:"socket"', "reline" => "shadowed:nil" },
      RunRubyWasm.shadowed_stub_candidates(probe_results)
    )
  end

  def test_empty_when_nothing_shadowed
    probe_results = { "socket" => "loaderror", "bigdecimal" => "ok" }
    assert_equal({}, RunRubyWasm.shadowed_stub_candidates(probe_results))
  end
end

class TestDetectPathCollisions < Test::Unit::TestCase
  def test_no_collision_when_paths_are_disjoint
    gem_files = {
      "csv" => ["csv.rb", "csv/parser.rb"],
      "rexml" => ["rexml/document.rb"]
    }
    assert_equal({}, RunRubyWasm.detect_path_collisions(gem_files))
  end

  def test_collision_when_two_gems_share_a_relative_path
    gem_files = {
      "gem-a" => ["shared.rb"],
      "gem-b" => ["shared.rb", "unique.rb"]
    }
    collisions = RunRubyWasm.detect_path_collisions(gem_files)
    assert_equal(["gem-a", "gem-b"], collisions.fetch("shared.rb").sort)
  end
end
