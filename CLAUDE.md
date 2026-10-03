# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository. What holds for one module only is in that module's own `modules/<name>/CLAUDE.md`.

## What this is

`cjls` is a Language Server Protocol implementation for the **Cangjie** language, written in Cangjie itself — an early-stage MVP built bottom-up: a `jsonrpc` peer, the generated LSP types, a handler framework with the lifecycle, document sync, and what the syntax tree alone can answer (`handlers/router.cj` says which requests). Under it is `loupe`, the query-driven incremental analysis on `calca`, knowing no LSP.

**[`docs/`](docs/README.md)** holds the rules (`design/`: tables, no prose), the decisions (`adr/`: one per file, superseded, never rewritten) and the servers cjls is measured against (`prior-art.md`: rust-analyzer is the model, cjc the specification, D15). Update them in the same change as the code they describe, but write only what is new — a rule, a real decision, an open question — never what repeats a rule or lists what the code holds ([when a change writes there](docs/README.md#when-a-change-writes-here)). Cite ids (`S3`, `A2`, `C7`, `D5`, `R1`). Open questions are GitHub issues labeled `question` (an ADR's `Q#`: search the issues for it). There is no DESIGN.md, on purpose.

## Build & test

`cjpm` is on `PATH` in Claude Code sessions (a `SessionStart` hook in `.claude/settings.json` loads `envsetup.sh` for every Bash command — don't `source` it). In a shell of your own: `source ~/.cangjie/envsetup.sh` once. From the repo root:

- `cjpm build` · `cjpm run` (the server) · `cjpm clean`; `target/release/bin/cjls project [--dir <dir>]` prints the project the server finds for `<dir>` (the current directory by default) as `cj-project.json` (D33)
- `cjpm test --target-dir target/test` — all tests (the `pre-push` hook runs it). CI adds `--no-progress`: the progress report stalls now and then and fails a run whose tests all passed.
- `python3 tests/corpora/fetch.py` — the third-party suites `cjpm test` holds fjson and ftoml to (JSONTestSuite, toml-test), fetched into `.corpora/` at the commits it pins ([D26](docs/adr/0026-test-suites-are-fetched.md)); once per clone, and again when a pin moves. Without them those tests fail, naming it. The `pre-push` hook and CI run it first.
- A subset: `cjpm test --target-dir target/test '--filter=ConnectionCloseTest.*'` (`<TestClass>.<testCase>`, `*` wildcards). Quote it: the user's shell is fish.

**Builds are incremental** ([D27](docs/adr/0027-incremental-builds.md)): cjpm knows a source by its mtime alone and the compiler not at all, so `build.cj` starts from scratch under another `cjc --version`, and `cjpm clean` is for a file put back with its old mtime (`cp -p`, an archive). Tests go to `target/test`: `cjpm test` and `cjpm build` in one directory undo each other's cache. CI restores `target` from master's last build, the sources stamped with one mtime per directory made of its content (cjpm reads a package's imports again only when its newest mtime changed, D28); a tag builds clean.

`cjpm` leaves `*.cj.macrocall` and `lib-macro_*.dylib` next to the sources: untracked build output, never edit it.

**Toolchain, CI, releases** ([D11](docs/adr/0011-ci-and-releases.md), [D21](docs/adr/0021-weekly-releases.md)). One nightly, the tag in `.cangjie-version`; `python3 .github/actions/setup-cangjie/setup.py <tag> <dir>` installs it with stdx, as CI does. stdx lives in `${CANGJIE_HOME}/third_party/stdx/<os>_<arch>_cjnative/static/stdx`, named per target in the root `cjpm.toml`. CI (macOS arm64, Linux x64, Windows x64) builds, tests, runs the lone binary through `tests/e2e` (no editor client: each tests itself against this CI's build of a paired branch, [D32](docs/adr/0032-one-process-for-server-and-clients.md)), and checks commits and the PR **title** with `cog` (PRs are squash-merged). A release is `cog bump --auto` on master (version into `modules/cjls/cjpm.toml` and `VERSION` in `handlers/lifecycle.cj`, `CHANGELOG.md`, tag); `bump.yml` runs it on Mondays, `release.yml` attaches the binaries; `nightly.yml` moves the pre-release `nightly-build` to master's newest green commit every night, in place: never delete it ([D39](docs/adr/0039-the-nightly-is-updated-in-place.md)).

### Linking and compiler flags

- **Every library is `output-type = "static"`, on the static stdx.** Across a shared-library boundary cjc drops stdx extensions' funcTables at a user type, and the process aborts at run time (`F funcTable is nullptr, ti: …`, SIGABRT, compiles cleanly). An abort naming stdx is linkage: check `grep output-type modules/*/cjpm.toml` first.
- **`cjls` is linked `--static`** (its `package-configuration`): std and the runtime go in, so it runs without the SDK env, as an editor launches it. The generators are not: they call `cjfmt`, so the SDK is there. Linux needs LLVM's `libc++-dev`/`libc++abi-dev` to build it.
- **`-O2` is in every module's `compile-option`**, not only the root's: cjc defaults to `-O0`, and `cjpm build -m` reads the module's manifest alone. Don't dedupe.
- **No `-Woff unused` in a `compile-option`**: a build warns about nothing. Only the generated `cjls.lsp_types` (its `package-configuration`) and the tests (the root's `[profile.test.build]`: std.unittest's `@AssertThrows[E]` warns for an `E` not `open`) are silenced, and `driver-arg` on the `cjls` package (`cjpm test` builds it as a staticlib, where `--static` does nothing). std's `@Derive` warns on an enum constructor with a parameter: write `==` and `hashCode` by hand there.
- **`-O2` miscompiles `list.remove(at: i)[1]`** (a tuple or struct taken apart straight from `ArrayList.remove`): read `list[i]` first, then remove.
- **No LTO** ([D20](docs/adr/0020-no-lto.md)), **no `-dead_strip`** (the runtime aborts on the first message), **no `std.ast` in runtime packages** (a `ToTokens` reachable from `cjls` links the compiler's parser, two thirds of the binary).

### Commits

Conventional Commits, enforced by [cocogitto](https://docs.cocogitto.io/) (`cog`) on `commit-msg`: `type(scope): subject` (`feat(jsonrpc): ...`; `cog commit feat jsonrpc "subject"` writes one). Merge and `fixup!`/`squash!`/`amend!` pass; a `git revert` message must be reworded to `revert: ...`. Hooks are plain scripts in `.githooks/` (`commit-msg`: `cog verify`; `pre-push`: the fetch and the tests), activated per clone with `git config core.hooksPath .githooks`.

## Workspace layout

Members of the root `cjpm.toml`. A module is a library that knows nothing of the server; what only the server has is a package of `cjls` ([D3](docs/adr/0003-modules-and-packages.md)). All libraries are `static` (see *Linking*).

| module | what |
|---|---|
| `calca` | incremental computation: inputs, interned values, memoized tracked functions; `calca` runtime + `calca.macros` |
| `rope` | `Rope`, immutable UTF-8 text as a B-tree, and LSP's line/column arithmetic ([D1](docs/adr/0001-files-are-ropes.md)) |
| `fnum` | numbers as text, for `fjson` and `ftoml`: Ryu (`formatShortest`) and a correctly rounded `parseFloat64` (`Float64.parse` is not) |
| `fjson` | JSON over bytes, no tree: `FjReader`, `FjWriter`, `ToJson`/`FromJson`, `RawJson`; `JsonValue`, any JSON as a tree, which `LSPAny` aliases (D22, D24) |
| `ftoml` | TOML 1.1.0 (D25): `parseToml` into an `FtDocument` with spans, `FtWriter`, `ToToml`/`FromToml`, TOML's date-times of its own |
| `stdxx` | sum types (`Nullable`, `IntegerOrString`) and the `@DeriveExt`/`@Serde` derive macros |
| `jsonrpc` | the JSON-RPC peer; knows **zero method names** |
| `index_map` | `IndexMap`/`IndexSet` (insertion order) and their append-only concurrent versions; anything that interns uses them |
| `ginkgo` | lossless green/red syntax trees, and the grammar-agnostic parser machinery |
| `cjsyntax` | the Cangjie lexer and parser on `ginkgo`; `SyntaxKind` and `cjsyntax.ast` are generated |
| `syntax_codegen` | executable: generates `cjsyntax`'s kinds and typed views |
| `loupe` | the analysis: `loupe.vfs`, `loupe.db`, `loupe.syntax`, the API in `loupe` ([D5](docs/adr/0005-loupe-knows-no-lsp.md)) |
| `cjo` | the `.cjo` files cjc writes for a package: `openCjo`, a read-only flatbuffers runtime and the views of the vendored `CjoFormat.fbs`, generated ([D37](docs/adr/0037-cjo-files-are-read-by-generated-views.md)) |
| `fbs_codegen` | executable: generates `cjo`'s views from a flatbuffers schema |
| `project_model` | how files make a project: `cj-project.json`, `cjpm.toml` or loose files, lowered to `loupe.db`'s `ProjectModel` ([D33](docs/adr/0033-project-model.md)); where the SDK is ([D40](docs/adr/0040-the-sdk-is-found-without-cangjie-home.md)) |
| `cjls` | executable: the server — handlers, framework, `@LspHandler`, generated `cjls.lsp_types`, hand-written `cjls.lsp_ext` (methods beyond LSP, [lsp-extensions.md](docs/lsp-extensions.md)) |
| `lsp_codegen` | executable: generates `cjls.lsp_types` from `metaModel.json` (checked in, never hand-edited) |

Dependencies flow one way ([00-layers.md](docs/design/00-layers.md)): `cjls → jsonrpc → stdxx → fjson → fnum`; `cjls → loupe → {calca, cjo, cjsyntax → ginkgo, index_map, rope}`; `cjls → project_model → {loupe, stdxx, ftoml}`. The generators sit outside, on `stdxx` and `ftoml` (`→ fnum`; `lsp_codegen` also `fjson`).

Editor integrations are repositories in the `ide4cj` organization ([D16](docs/adr/0016-editor-integrations-are-repositories.md)): Neovim ([`ide4cj/cangjie.nvim`](https://github.com/ide4cj/cangjie.nvim)), VS Code ([`ide4cj/cangjie-vscode`](https://github.com/ide4cj/cangjie-vscode)), Zed ([`ide4cj/cangjie-zed`](https://github.com/ide4cj/cangjie-zed)); a change across them is one branch name in each (D32), the process in [`ide4cj/.github`](https://github.com/ide4cj/.github). The server's root is the nearest `cjpm.toml`.

## Rules that cross modules

- **Never print** in the server: stdout is the LSP wire. Loggers are passed down, never global.
- **Never `await()` an outbound request from a read-loop callback** (a `Context` handler): its answer can only arrive through the loop the callback holds.
- **A `spawn`ed thread that throws dumps its stack to stderr** even if nobody reads the future: every `spawn` boundary catches internally, an `Error` as well as an `Exception` (S13).
- **A blocking foreign function is never `@FastNative`**, nor named like a libc function LLVM knows (`read`, `write`, …): the GC stalls while a thread blocks in one (C5, D13).
- **Enum constructors are in scope unqualified** throughout their package and past an import: generated code never writes a bare `None`, union variants are `As<Member>`, `SyntaxKind` never names a kind like a type (`ResourceDecl`, `Int64Kw`).
- **Anything that goes out on an LSP wire needs `@Serde[skipNone]`**: LSP tells an absent key from `null`. The optional/nullable mapping is in `modules/stdxx/CLAUDE.md`.

### Macro packages

`stdxx.deriving`, `cjls.macros` and `calca.macros`, on `std.ast.*`. Generated code is `quote(...)` templates naming things unqualified, so the using package imports what it refers to: `@DeriveExt[ToJson, FromJson]` needs `fjson.*` and `stdxx.deriving.*`; `@DeriveExt[ToToml, FromToml]` `ftoml.*` and `stdxx.deriving.*`, plus `stdxx.Nullable` when used. A green build of a macro package is no evidence its output compiles — a build of a package *using* it is. A macro may emit a static or global only if its initializer reaches nothing the user wrote (cjc follows calls for use-before-initialization: two `@CalcaTracked` functions calling each other would fail), and no package's initialization may rely on another's: the order is undefined.

## Testing

Tests are a pyramid (C7): a case a unit test can cover is never an e2e test.

- **Unit tests** live beside the code as `*_test.cj` in the same package, `std.unittest` (`@Test`/`@TestCase`, `@Expect`/`@Assert`/`@AssertThrows`). Cases in `// arrange` / `// act` / `// assert`, named as sentences (`closeWakesACallerWaitingForAnAnswer`).
- **Every platform**: paths are `std.fs.Path`, URIs stdx's `URL` (C6), absolute paths under `getTempDirectory()`; platform-only cases go in a `@When[os == …]` class of their own.
- **Random inputs** are std.unittest's own (`Arbitrary` + `Shrink`), never a seed and `std.random`. Fuzzing: `@Configure[coverageGuided: true]`, run with `cjHeapSize=2GB cjpm test --fuzz --target-dir target/fuzz '--filter=*CoverageGuided*.*'` (D24).
- **The analysis** as fixtures ([D43](docs/adr/0043-analysis-tests-are-fixtures.md)): files, a `$0` and the expected answers as `//^^^ text` in one raw string, `loupe.fixture` setting the database and the project model from it (`checkDiagnostics` in `loupe`'s tests). A case is written by running it: `UPDATE_EXPECT=1 cjpm test --target-dir target/test '--filter=…'` writes the answers into the test, to be read in its diff.
- **Concurrency** deterministically, never with sleeps: `connection_test.cj`'s `FakeTransport` and handlers parked on a `LinkedBlockingQueue` are the pattern.
- **Performance** with `@Bench` in `*_bench_test.cj`, `cjpm bench '--filter=VfsPathBench.*'`; not part of `cjpm test`; never a hand-rolled timing loop.
- **End-to-end**: pytest-lsp over real stdio, `cjpm build && uv run --project tests/e2e pytest tests/e2e` (`CJLS_BIN` overrides the binary); fixtures `server` (uninitialized) and `client` (initialized as each editor would). Neovim: `CJLS_BIN=$PWD/target/release/bin/cjls nvim --clean --headless -u ../cangjie.nvim/test/run.lua` from a sibling clone (`TEST=cjls` for the server's cases).
- **Whole-server speed and memory**: `tests/perf` ([D23](docs/adr/0023-performance-is-measured-over-stdio.md)). `uv run --project tests/perf cjls-perf run --server cjls --server lsp-server -o perf.json`; `cjls-perf compare a.json b.json`; `cjls-perf list`. Servers are entries in `servers.toml`, scenarios functions in `cjls_perf/scenarios.py`.
