package loupe

import std.unittest.*
import std.unittest.testmacro.*
import ginkgo.TextRange
import rope.Rope
import loupe.vfs.FileId
import loupe.db.AnalysisDatabase

func diagnosticsOf(text: String): Array<Diagnostic> {
    let db = AnalysisDatabase()
    db.setFileText(FileId(0), Rope(text))
    diagnostics(db, FileId(0))
}

@Test
class DiagnosticsTest {
    @TestCase
    func aFileThatParsesHasNone() {
        // act
        let result = diagnosticsOf("func f(): Int64 { 1 }\n")

        // assert
        @Expect(result.size, 0)
    }

    @TestCase
    func aSyntaxErrorIsAnErrorWhereTheParserPutIt() {
        checkDiagnostics(#"
            class A {
            //       | error: expected '}'
            "#)
    }

    @TestCase
    func eachFileHasItsOwn() {
        checkDiagnostics(#"
            //- /a.cj
              func f() {
                  let x =
            //           | error: expected an expression
              }
            //- /b.cj
            func g(): Int64 { 1 }
            //- /c.cj
              class C { func }
            //              | error: expected '('
            //              | error: expected a name
            "#)
    }

    @TestCase
    func theyComeInTheOrderOfTheText() {
        // act
        let result = diagnosticsOf("let a = \nlet b = \n")

        // assert
        @Expect(result.map {diagnostic => diagnostic.range}, [TextRange(7, 7), TextRange(16, 16)])
    }

    @TestCase
    func aFileTheDatabaseDoesNotKnowHasNone() {
        // arrange
        let db = AnalysisDatabase()

        // act
        let result = diagnostics(db, FileId(0))

        // assert
        @Expect(result.size, 0)
    }
}
