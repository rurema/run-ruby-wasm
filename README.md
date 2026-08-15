# run-ruby-wasm

[docs.ruby-lang.org](https://docs.ruby-lang.org/ja/) の RUN ボタン (bitclust
`statichtml --run-ruby-wasm` / doctree Rakefile の `ruby_wasm_url`) が読み込む
`ruby.wasm` を作るリポジトリです。

## 概要

RUN ボタンは、マニュアルのサンプルコードをブラウザ内で実際に Ruby を動かして
実行するための機能です。実行エンジンには [ruby/ruby.wasm](https://github.com/ruby/ruby.wasm)
が npm で配布している `@ruby/<series>-wasm-wasi` パッケージ (中身は
`ruby+stdlib.wasm`) を使います。

このリポジトリがビルドする `dist/ruby-<series>.wasm` は、その npm 配布物に
Ruby 本体の bundled gems (純 Ruby のもの) を追い焼きし、提供できないライブラリ
には分かりやすいメッセージが出るスタブを足したものです。bitclust の
`theme/default/js/run-worker.js` が読み込む VM ローダー本体 (npm package) は
差し替えません。差し替えるのは wasm バイナリ本体だけです。

## なぜ必要か

上流 `@ruby/*-wasm-wasi` の npm 配布物 `ruby+stdlib.wasm` には、Ruby の
bundled gems (`csv`・`ostruct`・`matrix`・`rexml` など、gems/bundled_gems に
載っている純 Ruby ライブラリ) が入っていません。そのため、マニュアルの
サンプルコードが `require "csv"` などを呼ぶと `LoadError` になり、RUN ボタンで
実行できないサンプルが多数あります。

この問題は上流でも認識されており、[ruby/ruby.wasm#14](https://github.com/ruby/ruby.wasm/issues/14)
で bundled gems の同梱が議論されています。ただし上流ビルドにどこまで・いつ
取り込まれるかは不確定なため、当面の間はこのリポジトリで再パックして
埋め合わせます。**ruby/ruby.wasm のフォークではありません** — 上流の
成果物 (npm パッケージ) をそのまま入力にして、その上に薄く追い焼きする層です。

## 仕組み

「probe して足りないものだけ足す」自己適応型のビルドです。

1. 対象シリーズの `ruby+stdlib.wasm` をダウンロードする
2. 対応する `ruby/ruby` ブランチから `gems/bundled_gems` を取得する
3. C 拡張やネットワーク・端末機能に依存する gem (`EXCLUDED_GEMS`) を除外する
4. **probe**: ベースの wasm を一度起動し、残った候補 gem のフィーチャーと、
   スタブ候補の feature (`STUB_FEATURES`) それぞれについて実際に `require`
   してみて `ok` / `loaderror` を調べる
5. `loaderror` だった gem だけを `gem install` して `lib/` を wasm に
   埋め込み、`loaderror` だった feature だけにスタブを生成する
   (`ok` だったものには一切手を加えない)
6. `rbwasm pack` で一度だけ焼き込み、`dist/ruby-<series>.wasm` を作る
7. 焼き込んだ wasm に対して verify (add した gem が本当に require
   できるか・スタブが期待通り LoadError になるか・stdlib が壊れていないか)
   を実行し、失敗したらビルド全体を失敗させる

この設計により、**上流が bundled gems を同梱するようになった項目は、
probe で `ok` になった時点で自動的に何も足さなくなります**。将来
すべての対象が上流でカバーされたら、このリポジトリはやることが無くなるので
archive するだけで撤収できます。

一部のベース wasm (Ruby 3.2 系で確認) は、除外対象の gem (`net-ftp`・`rbs`・
`reline` など) を実体としてインストール済みですが、その依存
(`socket`・`io-console` gem など) が無いため壊れています。この場合
`require` は `LoadError` になりますが、実体のファイル (または gemspec) が
`site_ruby` より先に見つかる/優先されるため、スタブを置いても絶対に
読まれません。probe は `LoadError#path` が要求した feature 名と一致するか
どうかでこれを判別し (`manifest.json` の `stub_shadowed` に記録)、一致しない
場合はスタブを生成せず素の `LoadError` のまま残します。読まれないスタブで
「親切なメッセージを出す」と偽るよりは、何もしない方が誠実だからです。

## スタブとは

`socket`・`io/console`・`bigdecimal` (C 拡張ビルドが無い版のみ) など、
ブラウザ内の ruby.wasm では原理的に提供できない機能に対して、
`require` した瞬間に **本物の `LoadError` と互換性のある** 例外を送出する
小さな Ruby ファイルです。

- `LoadError` のサブクラスではなく `LoadError` そのものを raise するので、
  `rescue LoadError` によるフィーチャー検出パターン (gem がよくやる
  「あれば使う」判定) が壊れません。
- `@path` を設定してあるので `e.path` が本物の `LoadError` と同じように
  振る舞います。
- メッセージは「`<feature>` は`<理由>`、ブラウザ内で実行される ruby.wasm
  では利用できません。このサンプルはお手元の Ruby で実行してください」という
  分かりやすい文言になっています (素の `cannot load such file -- <feature>`
  だけだと初見では原因が分かりにくいため)。

なお、**probe で `ok` (= ベースの wasm に既にネイティブ実装がある) だった
feature には絶対にスタブを置きません**。たとえば 3.2/3.3 系では
`bigdecimal`・`nkf` が wasm 本体に組み込み済みで動くため、ここでスタブを
被せてしまうと動くはずのものを壊してしまいます。

## ビルド方法

### GitHub Actions

`workflow_dispatch` で手動起動します。

- `release_tag` を空のまま実行 → 全シリーズをビルドして artifact
  (`dist/*.wasm` + `dist/*.manifest.json`) を保存するだけ
- `release_tag` にタグ名 (例: `2026.08.15`) を指定 → 上記に加えて
  そのタグ名で GitHub Release を作成し、wasm と manifest を添付する

`pull_request` と `main` への `push` でも自動的にビルド (verify 込み) が
走り、壊れていないかを確認します。

### ローカル

```console
$ bundle install
$ npm install
$ ruby test/test_build.rb   # 純粋関数のユニットテスト (ネットワーク不要)
$ ruby build.rb 4.0         # 1 シリーズだけビルド (全シリーズなら引数無し)
```

`rbwasm` コマンド (gem `ruby_wasm` に同梱) と `node` (22 系) が必要です。

## 成果物

- `dist/ruby-<series>.wasm` — 追い焼き済みの wasm 本体
- `dist/ruby-<series>.manifest.json` — 何を足して何を除外・スタブ化したかの
  記録 (`gems_added` / `gems_skipped_present` / `gems_excluded` / `stubs` /
  `native_ok` / ベース wasm の URL と sha256 など)

サイズの目安: ベースの `ruby+stdlib.wasm` が概ね 25〜33MiB、追い焼きによる
増分はベース wasm に何が既に入っているか (= 何を足す必要があるか) で
大きく変わります。実測 (2026-08 時点、npm dist-tag `2.9.3-2.9.4`) では、
Ruby 4.0 は 17 gem を追加して +3.5MiB 程度、Ruby 3.2 はベースに候補 gem が
ほぼ全て既に入っていたため gem 追加は 0 件・スタブのみで +25KiB 程度でした。

## 設定の更新

上流の npm パッケージが新しいバージョンを出したときは、`config.rb` の
`NPM_VERSION` を新しい dist-tag に上げてから `workflow_dispatch` で
再ビルドしてください (bitclust 側のローダー pin も同じバージョンに
揃える必要がある点に注意)。それ以外の設定 (対応 Ruby シリーズ・除外 gem・
スタブ対象) も同じ `config.rb` にまとまっています。

## 制限

- C 拡張に依存する gem (`bigdecimal`・`debug`・`rbs`・`nkf`・`syslog`・
  `fiddle` など) は追加できません。ベースの wasm が組み込みで対応して
  いない限り、`require` すると分かりやすいメッセージ付きの `LoadError`
  になります。
- OS のネットワーク機能 (`socket` およびそれに依存するもの) や、端末
  (コンソール) 機能 (`io/console`・`reline`・`irb` など) に依存するものも
  同様に提供できません。
- Windows 専用の `win32ole` も対象外です。
