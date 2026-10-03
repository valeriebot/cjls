package loupe.fixture

import std.env.getTempDirectory
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import ginkgo.TextRange
import loupe.vfs.*
import loupe.db.*

@Test
class FixtureTest {
    @TestCase
    func aTextOfNoHeaderIsOneFileAtMainOfTheDefaultModule() {
        // act
        let fixture = Fixture.parse("func f() {}\n")

        // assert
        @Expect(fixture.files.size, 1)
        let file = fixture.files[0]
        @Expect(file.path, pathOf("/main.cj"))
        @Expect(file.module, "default")
        @Expect(file.pkg, "default")
        @Expect(file.text, "func f() {}\n")
    }

    @TestCase
    func theIndentOfATestAndItsFirstAndLastLinesAreLeftOut() {
        // act
        let fixture = Fixture.parse(#"
            class A {
                func f() {}
            }
            "#)

        // assert
        @Expect(fixture.files[0].text, "class A {\n    func f() {}\n}\n")
    }

    @TestCase
    func aTextNotEndingInALineBreakKeepsItsLastLineAsIs() {
        // act
        let fixture = Fixture.parse("class A {")

        // assert
        @Expect(fixture.files[0].text, "class A {")
    }

    @TestCase
    func headersStartFilesOfModulesAndPackages() {
        // act
        let fixture = Fixture.parse(#"
            //- /app/src/main.cj module=app deps=lib
            package app
            //- /app/src/util/u.cj module=app package=app.util
            package app.util
            //- /lib/src/l.cj module=lib
            package lib
            "#)

        // assert
        @Expect(fixture.files.map {file => file.text}, ["package app\n", "package app.util\n", "package lib\n"])
        @Expect(fixture.file("/app/src/util/u.cj").fileId.index, 1)
        let model = fixture.projectModel()
        @Expect(model.modules.map {module => module.name}, ["app", "lib"])
        let app = model.modules[0]
        @Expect(app.root, pathOf("/app/src"))
        @Expect(app.deps, ["lib"])
        @Expect(app.packages.map {pkg => pkg.name}, ["app", "app.util"])
        @Expect(app.packages[1].dir, pathOf("/app/src/util"))
        @Expect(app.packages[1].files, [pathOf("/app/src/util/u.cj")])
        @Expect(model.modules[1].root, pathOf("/lib/src"))
    }

    @TestCase
    func theDatabaseHoldsTheProjectAndTheTexts() {
        // arrange
        let fixture = Fixture.parse(#"
            //- /a.cj package=p
            let a = 1
            //- /b.cj package=p
            let b = 2
            "#)

        // act
        let db = fixture.database()

        // assert
        let files = fixture.files.map {file => file.fileId}
        @Expect(db.sourceFile(files[1]).getOrThrow().text(db).toString(), "let b = 2\n")
        let modules = db.project().getOrThrow().modules(db)
        @Expect(modules.map {module => module.name(db)}, ["default"])
        @Expect(modules[0].packages(db).map {pkg => pkg.files(db).map {file => file.index}}, [[files[0].index, files[1].index]])
    }

    @TestCase
    func aDollarZeroIsTheCursorAndTwoAreTheSelection() {
        // act
        let cursor = Fixture.parse("let a$0 = 1\n")
        let selection = Fixture.parse("let $0a$0 = 1\n")

        // assert
        @Expect(cursor.files[0].text, "let a = 1\n")
        @Expect(cursor.cursor.getOrThrow().offset, 5)
        @Expect(cursor.selection.isNone())
        @Expect(selection.files[0].text, "let a = 1\n")
        @Expect(selection.selection.getOrThrow().range, TextRange(4, 5))
        @Expect(selection.cursor.isNone())
    }

    @TestCase
    func caretsAnnotateTheLineAboveThemThatIsNoAnnotation() {
        // act
        let fixture = Fixture.parse(#"
            let first = 1
            let second = 2
              //^^^^^^ name
                     //| empty
                 //^ one
            "#)

        // assert
        let file = fixture.files[0].fileId
        @Expect(fixture.files[0].text, "let first = 1\nlet second = 2\n")
        @Expect(fixture.annotations, [
            Annotation(file, TextRange(18, 24), "name"),
            Annotation(file, TextRange(25, 25), "empty"),
            Annotation(file, TextRange(21, 22), "one")
        ])
    }

    @TestCase
    func aColumnPastTheEndOfALineIsPastItsLineBreak() {
        // act
        let fixture = Fixture.parse("class A {\n//        | expected\n")

        // assert
        @Expect(fixture.annotations[0].range, TextRange(10, 10))
    }

    @TestCase
    func aDollarZeroTakesNoColumnOfTheText() {
        // act
        let fixture = Fixture.parse("let x = f$0oo\n      //^^^^^ name\n")

        // assert
        @Expect(fixture.annotations[0].range, TextRange(8, 11))
        @Expect(fixture.cursor.getOrThrow().offset, 9)
    }

    @TestCase
    func aFixtureRendersAsItIsWritten() {
        // arrange
        let text = trimIndent(#"
            //- /a.cj module=m
              main() { f$0oo() }
            //^^^^ main
            //         ^^^^^ call
            //- /b.cj
            class A {
            //        | eof
            "#)
        let fixture = Fixture.parse(text)

        // act
        let rendered = fixture.render(fixture.annotations)

        // assert
        @Expect(rendered, text)
    }

    @TestCase
    func annotationsAreRenderedUnderTheirLinesInTheOrderOfTheirRanges() {
        // arrange
        let fixture = Fixture.parse("  let a = b\nlet c = d\n")
        let file = fixture.files[0].fileId

        // act
        let rendered = fixture.render([
            Annotation(file, TextRange(20, 21), "d"),
            Annotation(file, TextRange(10, 11), "b"),
            Annotation(file, TextRange(6, 7), "a"),
            Annotation(file, TextRange(11, 11), "")
        ])

        // assert
        @Expect(rendered, "  let a = b\n//    ^ a\n//        ^ b\n//         |\nlet c = d\n//      ^ d\n")
    }

    @TestCase
    func aRangeInTheFirstTwoColumnsOrAcrossLinesIsNotRendered() {
        // arrange
        let fixture = Fixture.parse("let a = b\nlet c = d\n")
        let file = fixture.files[0].fileId

        // act, assert
        @AssertThrows[FixtureException](fixture.render([Annotation(file, TextRange(0, 3), "let")]))
        @AssertThrows[FixtureException](fixture.render([Annotation(file, TextRange(4, 14), "two lines")]))
    }

    @TestCase
    func aFixtureThatSaysNothingClearIsRefused() {
        // act, assert
        @AssertThrows[FixtureException](Fixture.parse("//- /a.cj crate=a\n"))
        @AssertThrows[FixtureException](Fixture.parse("//- a.cj\n"))
        @AssertThrows[FixtureException](Fixture.parse("//- /a.cj\n//- /a.cj\n"))
        @AssertThrows[FixtureException](Fixture.parse("$0a$0b$0\n"))
        @AssertThrows[FixtureException](Fixture.parse("//- /a.cj\n$0\n//- /b.cj\n$0\n"))
        @AssertThrows[FixtureException](Fixture.parse("//^^ nothing above\n"))
    }

    @TestCase
    func aRenderedFixtureIsIndentedAsTheOriginal() {
        // arrange
        let original = "\n        a\n          b\n        "

        // act
        let indented = indentLike(original, "a\n//^ x\n  b\n")

        // assert
        @Expect(indented, "\n        a\n        //^ x\n          b\n        ")
        @Expect(trimIndent(indented), "a\n//^ x\n  b\n")
    }

    @TestCase
    func theOneRawStringOfAFixtureIsReplacedInItsTest() {
        // arrange
        let dir = scratch("replaced")
        File.writeTo(dir.join("a_test.cj"), "let s = #\"\n    a\n    \"#\nlet t = \"\n    a\n    \"\n".toArray())
        File.writeTo(dir.join("a.cj"), "let s = #\"\n    a\n    \"#\n".toArray())

        // act
        replaceInTests(dir, "\n    a\n    ", "\n    b\n    ")

        // assert
        @Expect(String.fromUtf8(File.readFrom(dir.join("a_test.cj"))), "let s = #\"\n    b\n    \"#\nlet t = \"\n    a\n    \"\n")
        @Expect(String.fromUtf8(File.readFrom(dir.join("a.cj"))), "let s = #\"\n    a\n    \"#\n")
    }

    @TestCase
    func aFixtureInTwoTestsIsNotReplaced() {
        // arrange
        let dir = scratch("twice")
        Directory.create(dir.join("sub"))
        File.writeTo(dir.join("a_test.cj"), "#\"x\"#".toArray())
        File.writeTo(dir.join("sub").join("b_test.cj"), "#\"x\"#".toArray())

        // act, assert
        @AssertThrows[FixtureException](replaceInTests(dir, "x", "y"))
        @Expect(String.fromUtf8(File.readFrom(dir.join("a_test.cj"))), "#\"x\"#")
    }
}

/**
 * An empty directory of the name in the temporary one.
 */
func scratch(name: String): Path {
    let dir = getTempDirectory().join("loupe-fixture-test").join(name)
    if (exists(dir)) {
        remove(dir, recursive: true)
    }
    Directory.create(dir, recursive: true)
    dir
}
