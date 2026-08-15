// Feature-availability probe for an unmodified (base) ruby+stdlib.wasm build.
//
// Instantiates DefaultRubyVM once and, for each requested feature, evals a
// small Ruby snippet that attempts `require` and returns one of:
//   "ok"          - require succeeded (the feature is already present)
//   "loaderror"   - require raised LoadError whose `path` is this exact
//                   feature (genuinely absent from $LOAD_PATH -- a stub
//                   placed under site_ruby would actually be found)
//   "shadowed:X"  - require raised LoadError, but for a DIFFERENT path X
//                   (a real, already-installed file for this feature exists
//                   earlier in $LOAD_PATH and is itself transitively broken,
//                   e.g. net-ftp's net/ftp.rb requiring "socket". A stub of
//                   ours would never be reached, see the comment on
//                   probeOne below)
//   "error:<Cls>" - require raised some other exception (unexpected; the
//                   caller treats this conservatively, see build.rb)
// No PRELUDE / stdout redirection is needed: the result comes back as a
// Ruby string via the `RbValue#toString()` returned by `vm.eval`, mirroring
// the technique proven in the PoC (see poc-a/verify.mjs for the analogous
// eval-and-read-back pattern using $stdout instead).
//
// Usage:
//   node js/probe.mjs <wasm-path> <features-json-path>
//
// <features-json-path> must contain: { "features": ["csv", "socket", ...] }
//
// Prints a single JSON object to stdout:
//   { "results": { "<feature>": "ok" | "loaderror" | "shadowed:..." | "error:<Class>", ... },
//     "load_path": ["<absolute path>", ...] }

import { readFile } from "node:fs/promises";

const [, , wasmPath, featuresPath] = process.argv;
if (!wasmPath || !featuresPath) {
  console.error("usage: node js/probe.mjs <wasm-path> <features-json-path>");
  process.exit(2);
}

const { features } = JSON.parse(await readFile(featuresPath, "utf8"));

const bytes = await readFile(wasmPath);
const module = await WebAssembly.compile(bytes);
const { DefaultRubyVM } = await import("@ruby/wasm-wasi/dist/browser");
const { vm } = await DefaultRubyVM(module, { consolePrint: false });

// JSON.stringify on a plain ASCII/Japanese feature name produces a string
// that is also a valid Ruby double-quoted string literal (Ruby source
// defaults to UTF-8, and our feature names never contain characters that
// JSON and Ruby disagree on how to escape).
function rubyStr(s) {
  return JSON.stringify(s);
}

// Some base wasm builds (observed on 3.2) ship a handful of excluded gems
// (net-ftp, rbs, reline, typeprof, ...) pre-installed for real, but broken
// (their own transitive requires, e.g. "socket", or -- for gems installed
// as real RubyGems specifications, e.g. reline -- a missing dependency such
// as "io-console" that RubyGems' activation step fails to satisfy).
// Requiring the top-level feature then raises a LoadError whose `path`
// points at that INNER missing thing (or is nil, for a Gem::LoadError from
// failed activation), not at the feature itself. Either way, a stub of
// ours placed under site_ruby would never actually be reached: for a real
// file, RubyGems' plain $LOAD_PATH scan (which runs before ours ever gets
// a chance) finds the broken file first; for a gem activation failure,
// RubyGems intercepts the require by its own installed-specs index before
// $LOAD_PATH is even consulted. We must not report "loaderror" for either
// case: build.rb would place a stub that can never actually be reached, so
// verify would then rightly fail on the promised-but-unreachable friendly
// message. Only a LoadError whose `path` matches the feature we asked for
// means "genuinely absent", i.e. a spot a stub of ours could actually fill.
function probeOne(feature) {
  const src = `
begin
  require ${rubyStr(feature)}
  "ok"
rescue LoadError => e
  if e.path == ${rubyStr(feature)}
    "loaderror"
  else
    "shadowed:#{e.path.inspect}"
  end
rescue Exception => e
  "error:#{e.class}"
end
`;
  return vm.eval(src).toString();
}

const results = {};
for (const feature of features) {
  results[feature] = probeOne(feature);
}

const loadPath = vm
  .eval('$LOAD_PATH.map(&:to_s).join("\\n")')
  .toString()
  .split("\n")
  .filter((s) => s.length > 0);

process.stdout.write(JSON.stringify({ results, load_path: loadPath }));
