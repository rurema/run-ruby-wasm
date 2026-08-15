// Post-build verification battery for a packed ruby-<series>.wasm.
//
// Mirrors the production RUN-button path in
// bitclust/theme/default/js/run-worker.js: fetch wasm bytes ->
// WebAssembly.compile -> DefaultRubyVM(module, { consolePrint: false })
// from npm @ruby/wasm-wasi -> vm.eval(...). No PRELUDE is needed here since
// every check reads its result back as a Ruby string via RbValue#toString()
// instead of writing to $stdout (same technique as js/probe.mjs).
//
// Usage:
//   node js/verify.mjs <wasm-path> <manifest-path>
//
// Prints one PASS/FAIL line per check to stdout and exits nonzero if any
// check failed (build.rb treats that as a build failure).

import { readFile } from "node:fs/promises";

const [, , wasmPath, manifestPath] = process.argv;
if (!wasmPath || !manifestPath) {
  console.error("usage: node js/verify.mjs <wasm-path> <manifest-path>");
  process.exit(2);
}

// Kept in sync with config.rb's Config::REQUIRE_NAMES. Small and stable
// enough (2 entries) that duplicating it here is simpler than growing the
// manifest.json schema with a derived field just for this script.
const REQUIRE_NAME_OVERRIDES = { racc: "racc/parser", rexml: "rexml/document" };
function requireNameFor(gemName) {
  return REQUIRE_NAME_OVERRIDES[gemName] ?? gemName.replaceAll("-", "/");
}

// Smoke checks for a fixed set of gems, run only when that gem is present
// in manifest.gems_added; silently skipped otherwise. Each body must
// evaluate to the Ruby literal `true` for a pass.
const SMOKE_CHECKS = {
  csv: `require "csv"; CSV.parse_line("a,b") == ["a", "b"]`,
  ostruct: `require "ostruct"; OpenStruct.new(a: 1).a == 1`,
  matrix: `require "matrix"; Matrix[[1, 2], [3, 4]].determinant == -2`,
  prime: `require "prime"; Prime.first(3) == [2, 3, 5]`,
  rexml: `require "rexml/document"; REXML::Document.new("<a><b/></a>").root.name == "a"`,
};

const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
const bytes = await readFile(wasmPath);

console.log(`=== verify ${wasmPath} (ruby-${manifest.ruby_version}) ===`);

const module = await WebAssembly.compile(bytes);
const { DefaultRubyVM } = await import("@ruby/wasm-wasi/dist/browser");
const { vm } = await DefaultRubyVM(module, { consolePrint: false });

let failures = 0;

function rubyStr(s) {
  return JSON.stringify(s);
}

// Evaluates `src` (a Ruby expression) inside a begin/rescue that reports
// any exception as a string, so a raise never becomes an uncaught JS
// exception; returns the resulting Ruby string.
function evalGuarded(src) {
  const wrapped = `
begin
  (${src}).to_s
rescue Exception => e
  "exception:#{e.class}:#{e.message}"
end
`;
  try {
    return vm.eval(wrapped).toString();
  } catch (e) {
    return `jsexception:${e && e.message ? e.message : e}`;
  }
}

function report(name, pass, detail) {
  console.log(`${pass ? "PASS" : "FAIL"} ${name}: ${detail}`);
  if (!pass) failures++;
}

function checkRequireSucceeds(label, feature) {
  const result = evalGuarded(`require(${rubyStr(feature)}); "ok"`);
  report(label, result === "ok", result);
}

function checkBooleanTrue(label, expr) {
  const result = evalGuarded(expr);
  report(label, result === "true", result);
}

function checkStubRaisesFriendlyLoadError(label, feature) {
  const src = `
begin
  require ${rubyStr(feature)}
  "did-not-raise"
rescue LoadError => e
  if e.message.include?("ruby.wasm では利用できません") && e.path == ${rubyStr(feature)}
    "ok"
  else
    "bad:message=#{e.message.inspect} path=#{e.path.inspect}"
  end
rescue Exception => e
  "wrong-class:#{e.class}:#{e.message}"
end
`;
  const result = vm.eval(src).toString();
  report(label, result === "ok", result);
}

// --- gems_added: require must now succeed ---------------------------------
for (const [name] of Object.entries(manifest.gems_added ?? {})) {
  checkRequireSucceeds(`gems_added[${name}] require`, requireNameFor(name));
}

// --- smoke checks for the fixed gem map, only when that gem was added ----
for (const [name, expr] of Object.entries(SMOKE_CHECKS)) {
  if (!Object.prototype.hasOwnProperty.call(manifest.gems_added ?? {}, name)) continue;
  checkBooleanTrue(`gems_added[${name}] smoke`, expr);
}

// --- stubs: require must raise our friendly LoadError ---------------------
for (const [feature] of Object.entries(manifest.stubs ?? {})) {
  checkStubRaisesFriendlyLoadError(`stubs[${feature}] LoadError`, feature);
}

// --- native_ok: require must still succeed after packing ------------------
for (const feature of manifest.native_ok ?? []) {
  checkRequireSucceeds(`native_ok[${feature}] require`, feature);
}

// --- stdlib regression ------------------------------------------------------
checkRequireSucceeds("stdlib json", "json");
checkRequireSucceeds("stdlib date", "date");
checkRequireSucceeds("stdlib yaml", "yaml");
checkBooleanTrue(
  "RUBY_VERSION series",
  `RUBY_VERSION.start_with?(${rubyStr(manifest.ruby_version)})`
);

console.log(`=== ${failures === 0 ? "ALL PASS" : `${failures} FAILURE(S)`} ===`);
process.exit(failures === 0 ? 0 : 1);
