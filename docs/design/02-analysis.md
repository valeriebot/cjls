# Analysis

## Pieces

| Piece | Where | Is |
|---|---|---|
| `Rope` | `rope` | immutable UTF-8 text, B-tree of chunks; edits share the rest (D1) |
| `Vfs` | `loupe.vfs` | `FileId → ?Rope` + changes folded until `takeChanges` (D2) |
| `PathInterner` | `loupe.vfs` | `FileId` = the path's index in the order seen, for good; a `ConcurrentIndexSet`, a lock only to give an id (C9); the only thread-safe part |
| `SourceFile` | `loupe.db` | `@CalcaInput { fileId, text: Rope }`, one per `FileId`, never dropped |
| `ProjectModel` | `loupe.db` | modules (named after their root package), packages and their files, binaries, `Cfg`: plain values, every way of finding a project comes down to it (D33) |
| `Project`, `Module`, `Package` | `loupe.db` | the model as inputs: `Project` a singleton, a `Module` per root and name and a `Package` per name in it, never dropped; a package's files a field of its own |
| `BinaryPackageFile` | `loupe.db` | `@CalcaInput { binary, name, path, bytes }`: a package compiled already, its `.cjo` as bytes, out of the `Vfs`; one per binary, package and path, never dropped, a gone one empty (D38) |
| `AnalysisDatabase` | `loupe.db` | the database; root handle or snapshot (D4, D9) |
| `parse` | `loupe.syntax` | `@CalcaTracked[lru: 128]`, backdated (`Parse` is `Equatable`); keeps the trees of the 128 files parsed last (D17) |
| `SyntaxNodePtr`, `AstPtr` | `ginkgo` | a node as its kind and range, resolved against a root: what a result keeps of a tree (A13) |
| `ItemId`, `itemIdMap` | `loupe.hir` | an item named so that edits elsewhere leave it, and the file's map of ids to pointers and back (D34) |
| `itemTree` | `loupe.hir` | what a file declares: package, imports, items by `ItemId`, no ranges, no bodies; equal after an edit inside a body (D34) |
| `binaryItemTrees`, `binaryExports` | `loupe.hir` | a `.cjo` in the same model: an `ItemTree` per file of the package, its re-exports its imports; an `exportId` to its item, an item back to its `Decl` (`binaryDecl`). `ItemFile` is either kind of file (D38) |
| loader | `loupe.vfs` | `readRoots` (the `*.cj` under the roots, within a budget), `readFiles`, `readFile`, `isWorkspaceFile`; `cjoFilesIn`, `readCjoFiles` (by stamp, header checked): the disk, nothing else (D30, D38) |
| project loaders | `project_model` | `cj-project.json`, `cjpm.toml`, loose files → `ProjectModel`; `findProjects` per root (D33); the SDK (`findCangjieHome`, D40) |
| API | `loupe` | a file per feature (`fileStructure`, …): plain functions over queries, speaking `FileId`, `TextRange` and loupe's own types (A3, A8) |

## Rules

| # | Rule |
|---|---|
| A1 | Every query takes `AnalysisDatabase` itself; no database interface (D4). |
| A2 | A query is keyed by an entity (`SourceFile`, interned ids), never by a position (D6): memo values are evicted (`lru`, D17), and interned values unused for a while are collected with the memos keyed by them (D18), but other keys live as long as the database. |
| A3 | Position-dependent API (`hover(db, position)`) is a plain function over queries. |
| A4 | Inputs are created and set on the root handle only, outside queries (`IllegalStateException` otherwise). |
| A5 | A deleted file is an empty text; its `FileId` and `SourceFile` stay. |
| A6 | Offsets are UTF-8 bytes on character boundaries, as `TextRange` and `Rope`. |
| A7 | Lines break at `\n` only, as the compiler's lexer; a line ends before the `\r` of `\r\n` (D1). |
| A8 | `loupe` knows no LSP: no URIs, `Position`, encodings or LSP types (D5). |
| A9 | Anything that interns (dense ids in first-seen order) is an `IndexSet`, or a `ConcurrentIndexSet` if shared between threads (`PathInterner`, C9; its `FileId`s are forever, A5), unless its values are collected: then a `Slab` of generations (calca's interned values and memo keys, D18). |
| A10 | A value a query returns is `Equatable`, so it backdates; `[noEq]` only with a reason. |
| A11 | Diagnostics are part of the results of the queries that find them (`Parse.errors`), never accumulated on the side (D14). |
| A12 | A diagnostic's range is what its source gives, an empty one included ("expected `}`" at the end of a file); widening it for a client is translation. |
| A13 | A tracked result holds no `SyntaxNode`, `SyntaxToken`, typed view, `GreenNode` or `Parse` (`parse` itself excepted), only `SyntaxNodePtr`/`AstPtr`: a node keeps its whole tree alive, and `lru` on `parse` frees nothing (D17). A handler holds nodes for the length of a request. |
| A14 | A query has a fallback on a cycle (`@CalcaTracked[cycleResult: f]`) only where the language gives a cycle a meaning of its own (glob imports reaching each other, a recursive type alias), and the fallback is what the compiler reports there (an unresolved name, an error type); anywhere else a cycle is a bug, and `CycleException` says so. |
| A15 | A question over every file holds no tree past the `lru` of `parse`, which evicts within a revision too (D36): what it keeps of a file is a summary with no node (`fileSymbols`, `itemTree`). One that needs no tree kept parses without `parse` (`fileSymbols`, D30), so a sweep does not push the open documents' trees out. |
| A16 | What the server reads from disk is bounded: a load keeps at most its budget of text and `.cjo` (D30, D38), a sixteenth of the heap (D31). |
| A17 | A file's input has its module's durability: `Low` for the user's, `Medium` for a dependency's, `High` for `std`; a file of no module `Low`; a `.cjo` its binary's, `High` for `std`, `Medium` for any other. The project is set before the files it names, so they are created with it (D33). |
| A18 | Which files a package has is `Package.files`, never found from the texts: a file deleted is an empty text (A5). Visibility (`protected`, `internal`) is computed from package names, not from `Module`: a module is a unit of the build, cjc's is the first segment of a name (D33). |
| A19 | What outlives an edit names an item by its `ItemId`, never by a pointer: a result holding a `SyntaxNodePtr` changes with every edit above it, and so does everything that read it. Items come from `itemTree`, nodes back through `itemIdMap` (D34). |
| A20 | A name is its `Name.text()` or `NameRef.text()`, never the text of its node or token: `` `foo` `` is `foo`, and a name compared, hashed into an `ItemId` or shown keeps no backquotes. |
| A21 | A query body never catches `Exception` around a calca call, only what it means to tolerate: calca unwinds with `Exception`s, and a body catching one stores nothing and throws it again (D41). A handler interns nothing the user types: interned outside a query, a value is `High`, kept forever (D18). |
