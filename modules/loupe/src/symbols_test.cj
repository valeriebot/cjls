package loupe

import std.unittest.*
import std.unittest.testmacro.*
import rope.Rope
import loupe.vfs.FileId
import loupe.db.AnalysisDatabase

/**
 * A database of one file per text, the first `FileId(0)`.
 */
func databaseOf(texts: Array<String>): AnalysisDatabase {
    let db = AnalysisDatabase()
    for (i in 0..texts.size) {
        db.setFileText(FileId(i), Rope(texts[i]))
    }
    db
}

/**
 * What a search found, as `name in container @ file` lines.
 */
func search(texts: Array<String>, query: String, limit!: Int64 = 128): Array<String> {
    let files = Array<FileId>(texts.size) {i => FileId(i)}
    workspaceSymbols(databaseOf(texts), files, query, limit).map {
        found => "${found.symbol.name} in ${found.symbol.containerName ?? "-"} @ ${found.fileId.index}"
    }
}

@Test
class WorkspaceSymbolsTest {
    @TestCase
    func aNameMatchesTheQuerysCharactersInOrderWhateverTheirCase() {
        // act
        let found = search(["class FooBar {}\nfunc fob() {}\nfunc bof() {}\nfunc other() {}\n"], "FB")

        // assert
        @Expect(found, ["FooBar in - @ 0", "fob in - @ 0"])
    }

    @TestCase
    func anEmptyQueryMatchesEveryDeclaration() {
        checkSymbols(#"
            //- /a.cj
            class A {
            //    ^ Class
                func f() {}
            //       ^ Method in A
            }
            //- /b.cj
            let x = 1
            //  ^ Variable
            "#, "")
    }

    @TestCase
    func aMemberIsFoundUnderWhatHoldsIt() {
        checkSymbols(#"
            class Outer {
                func target() {}
            //       ^^^^^^ Method in Outer
            }
            enum E { | Target }
            //         ^^^^^^ EnumConstructor in E
            "#, "target")
    }

    @TestCase
    func noMoreThanTheLimitAreFound() {
        // act
        let found = search(["func a1() {}\nfunc a2() {}\n", "func a3() {}\n"], "a", limit: 2)

        // assert
        @Expect(found, ["a1 in - @ 0", "a2 in - @ 0"])
    }

    @TestCase
    func aFileChangedIsSearchedAsItIsNow() {
        // arrange
        let db = databaseOf(["func before() {}\n"])
        @Expect(workspaceSymbols(db, [FileId(0)], "", 128).size, 1)

        // act
        db.setFileText(FileId(0), Rope("func after() {}\nfunc more() {}\n"))
        let found = workspaceSymbols(db, [FileId(0)], "", 128).map {found => found.symbol.name}

        // assert
        @Expect(found, ["after", "more"])
    }

    @TestCase
    func aNameWithoutTheQuerysCharactersIsNotFound() {
        // act
        let found = search(["func abc() {}\n"], "abcd")

        // assert
        @Expect(found.size, 0)
    }
}
