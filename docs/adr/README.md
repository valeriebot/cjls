# ADR

One decision per file, ≤ 1 page: the decision and why, not how it was reached — a benchmark's table goes in the PR, the ADR keeps the result. An accepted ADR is not rewritten: a new one replaces it, saying "supersedes ADR-NNNN". In discussion `D7` ≡ `ADR-0007`.

Template:

```md
# ADR-NNNN: <decision>

Status: proposed | accepted | superseded by ADR-NNNN, <date>

## Context
## Decision
## Consequences
```

| # | Decision | Status |
|---|---|---|
| [0001](0001-files-are-ropes.md) | Files are persistent ropes; lines break at `\n` | accepted |
| [0002](0002-vfs.md) | A VFS of `FileId`s and folded changes, as rust-analyzer's | accepted; Windows paths by D12 |
| [0003](0003-modules-and-packages.md) | A module is a library that knows nothing of the server | accepted |
| [0004](0004-one-database-class.md) | One database class, no interface ladder | accepted |
| [0005](0005-loupe-knows-no-lsp.md) | The analysis API knows no LSP; handlers translate | accepted |
| [0006](0006-handlers-are-not-queries.md) | Handlers are not queries; queries are keyed by entities | accepted |
| [0007](0007-position-encoding.md) | UTF-8 columns when the client offers them | accepted |
| [0008](0008-cancellation.md) | Two cancellations, two answers | accepted |
| [0009](0009-names-of-state-and-database.md) | `ServerState` holds the `AnalysisDatabase`; only calca says `Database` | accepted |
| [0010](0010-generated-syntax.md) | Syntax kinds and typed views are generated from an ungrammar | accepted |
| [0011](0011-ci-and-releases.md) | A pinned nightly toolchain, CI on three platforms, releases from `cog bump` | accepted; no editor's tests in CI by D32 |
| [0012](0012-drive-paths.md) | Paths are `std.fs.Path`, URIs are stdx's `URL`; Windows drives are spelled one way | accepted |
| [0013](0013-stdin-is-read-with-readv.md) | Stdin is read with `readv`, not `read`: cjc treats `read` as `@FastNative` | accepted |
| [0014](0014-diagnostics-pull-first.md) | Diagnostics are pulled; pushed, by the server after a write, only to clients that cannot pull | accepted |
| [0015](0015-reference-implementations.md) | rust-analyzer is the model, salsa the model for calca, cjc the specification; LSPServer and lin-qingying/cangjie the competitors | accepted |
| [0016](0016-editor-integrations-are-repositories.md) | Each editor integration is a repository of its own in ide4cj: `cangjie.nvim` for Neovim | accepted; how server and clients change together, and who tests which, by D32 |
| [0017](0017-lru-of-memo-values.md) | calca evicts memo values by LRU; a query result keeps pointers, never nodes | accepted; interned values by D18; eviction within a revision by D36 |
| [0018](0018-gc-of-interned-values.md) | calca collects unused interned values, and the memos keyed by them | accepted |
| [0019](0019-syntactic-highlighting.md) | Semantic tokens from the syntax tree first, in a fixed legend of LSP's own types | accepted |
| [0020](0020-no-lto.md) | The Linux binary is not linked with LTO: cjc miscompiles the stack maps under it | accepted |
| [0021](0021-weekly-releases.md) | A release every week from a green master; the first one by hand, its changelog written; versions of cjls's own | accepted; a nightly by D32 |
| [0022](0022-json-codec.md) | The wire is read and written with fjson, through serde's derives `ToJson`/`FromJson` and one `@Serde` marker | accepted |
| [0023](0023-performance-is-measured-over-stdio.md) | Speed and memory are measured over stdio, by one driver for every server | accepted |
| [0024](0024-fjson-conformance.md) | fjson is held to JSONTestSuite, vendored, and fuzzed in `cjpm test`; a lone surrogate reads as U+FFFD; 512 containers deep | accepted; the suite fetched by D26, `readFloat64` rounded correctly by D25 |
| [0025](0025-toml-through-serde.md) | TOML is read and written by ftoml, TOML 1.1 of our own, through `ToToml`/`FromToml` derived from the same `@Serde` model | accepted |
| [0026](0026-test-suites-are-fetched.md) | Third-party test suites are fetched into `.corpora/` at a pinned commit, not vendored | accepted |
| [0027](0027-incremental-builds.md) | Builds are incremental, clean on a new compiler and for a release; tests in `target/test`; CI caches `target` from master | accepted; stamps by D28 |
| [0028](0028-ci-stamps-a-package.md) | CI stamps a package's files with one mtime, made of the whole directory | accepted |
| [0029](0029-one-computation-per-memo.md) | One handle computes a memo, the others wait; a wait that closes a loop is a cycle | superseded by D35 |
| [0030](0030-workspace-loader.md) | The workspace is loaded on the read loop in one revision, under a budget of text, watched by the client; symbols are searched through a per-file index | accepted; what is loaded is the project's files by D33 |
| [0031](0031-the-server-sets-its-heap.md) | Without `cjHeapSize` the server starts over with a heap of 2 GB; a load keeps a sixteenth of the heap | accepted |
| [0032](0032-one-process-for-server-and-clients.md) | The server and its editor clients change by one process: the protocol their contract, paired branches, two channels, pins bumped by a bot | accepted; the nightly's tag `nightly-build`, updated in place, by D39 |
| [0033](0033-project-model.md) | A project is a model of loupe's, found from `cj-project.json`, `cjpm.toml` or loose files by `project_model`; the server loads its files | accepted; its binaries read by D38 |
| [0034](0034-item-ids-and-the-item-tree.md) | An item is named by a hash of its parent and its name; a file's items are a tree with no ranges | accepted |
| [0035](0035-a-handle-closing-a-loop-gives-way.md) | A handle closing a loop of waits gives way, and the owner computes the cycle; one memo per handle otherwise as D29 | accepted |
| [0036](0036-lru-evicts-within-a-revision.md) | calca evicts by LRU as it touches, within a revision too | accepted |
| [0037](0037-cjo-files-are-read-by-generated-views.md) | A `.cjo` is read through views generated from its vendored schema, on a runtime of our own, with no verifier; the enums a patch may extend are open | accepted |
| [0038](0038-binary-packages-are-inputs-of-their-bytes.md) | A package compiled already is an input of its `.cjo` bytes, out of the `Vfs`, read with the project and lowered into the item model | accepted |
| [0039](0039-the-nightly-is-updated-in-place.md) | The nightly is the pre-release `nightly-build`, made once and updated in place; immutable releases are off | accepted |
| [0040](0040-the-sdk-is-found-without-cangjie-home.md) | The SDK is found without `CANGJIE_HOME`: the editor's setting, the variable, cjsdk's default toolchain, `cjc` on `PATH`; it is what `${CANGJIE_HOME}` expands to | accepted |
| [0043](0043-analysis-tests-are-fixtures.md) | Analysis tests are fixtures: files, a place and the answers as one text in `loupe.fixture`, written into the test by `UPDATE_EXPECT=1` | accepted |
