# ADR-0043: Analysis tests are fixtures: files, a place and the answers as one text, written into the test by running it

Status: accepted, 2026-10-04

## Context

- Name resolution and types will be tested by thousands of cases of the shape "these files, the cursor here, the answer is that" (#113). A test of loupe built an `AnalysisDatabase`, set files and computed offsets by hand.
- rust-analyzer (R1) writes such a case as one text: `//- /path` headers, `$0` markers, `//^^^ text` annotations under the line they are about, and an expect-test that writes the actual answer into the test under `UPDATE_EXPECT=1`, from the macro's `file!()` and `line!()`.
- Cangjie has no `file!()` a function can take from its caller: `@sourceLine()` as a default argument is the callee's line.
- A package's `*_test.cj` files are seen by its own tests alone: helpers of `loupe` tests are not visible from `loupe.hir`'s.
- A range of a diagnostic can be empty (A12), and the code of a fixture starts at column 0, where `//` stands.

## Decision

- **A fixture is a text**, its indent left out: `//- /path module=… package=… deps=…` starts a file (the module `default`, the package the module's name, if not given; no header is the one file `/main.cj`); `$0` is the cursor, two of them a selection; `//^^^ text` is about the carets' range in the line above, `//| text` about the empty range before the bar. Columns are as written, `//` included: code annotated from its first two columns is indented by two, as R1 does.
- **The header sets the project model too**: a module per name, its root the deepest directory of its files, a package per name, its directory its first file's (D33). The files are under the temporary directory, absolute on every platform (C6).
- **`loupe.fixture` is a package of the library**, not a test file: every package of loupe tests through it. It knows `loupe.db` and `loupe.vfs`, not the API; a check over the API (`checkDiagnostics`, `checkSymbols`) is a test helper of the package the API is in. Nothing in `cjls` imports it, so the binary links none of it, `std.unittest` included.
- **`UPDATE_EXPECT=1` writes what a check got into its test**: the fixture is found by its text, a raw string `#"…"#` in exactly one `*_test.cj` under the working directory (the root, for `cjpm test`), and replaced, indented as it was. A fixture in two places, or not in a raw string, is not updated: the check says so.
- **A check compares the fixture rendered with its annotations to it rendered with the answers**: a failure is a diff of two fixtures, the code between the annotations.

## Consequences

- A case is written by running it, and read in review as the code it is about.
- Annotations say what is at a range, not in what order: the order of an answer (`workspaceSymbols` by file, then outline) stays a test of its own.
- A range across lines has no annotation; a check whose answer has one fails naming it.
- Two cases of the same fixture with different queries need it updated one at a time, or written apart once.
