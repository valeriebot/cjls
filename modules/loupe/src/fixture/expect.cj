package loupe.fixture

import std.collection.*
import std.env.getVariable
import std.fs.*
import std.sync.Mutex
import std.unittest.assertEqual

/**
 * The variable that makes a check write what it got into its test: `UPDATE_EXPECT=1 cjpm test`.
 */
public const UPDATE_EXPECT = "UPDATE_EXPECT"

/**
 * Checks the annotations of `fixture` are `actual`, the answers of the analysis. Under
 * `UPDATE_EXPECT` a fixture they are not is replaced in its test by one they are, the first
 * `*_test.cj` under the working directory holding it as a raw string (`#"…"#`), and the check
 * passes: a case is written by running it, then read.
 *
 * @throws FixtureException - if the fixture is to be updated and not exactly one test holds it
 */
public func expectAnnotations(fixture: String, actual: Array<Annotation>): Unit {
    let parsed = Fixture.parse(fixture)
    let expected = parsed.render(parsed.annotations)
    let got = parsed.render(actual)
    if (expected == got) {
        return
    }
    if (updating()) {
        replaceInTests(Path("."), fixture, indentLike(fixture, got))
    } else {
        assertEqual("expected", "actual", expected, got)
    }
}

func updating(): Bool {
    match (getVariable(UPDATE_EXPECT)) {
        case Some(value) => !value.isEmpty() && value != "0"
        case None => false
    }
}

/**
 * One update at a time, should two cases of one file be checked at once.
 */
let updates = Mutex()

/**
 * Replaces the raw string `original` by `replacement` in the one test under `root` holding it.
 *
 * @throws FixtureException - if no test, or more than one place, holds it
 */
public func replaceInTests(root: Path, original: String, replacement: String): Unit {
    synchronized(updates) {
        let found = ArrayList<(Path, String, Int64)>()
        for (file in testsUnder(root)) {
            let text = String.fromUtf8(File.readFrom(file))
            for (at in rawStringsOf(text, original)) {
                found.add((file, text, at))
            }
        }
        if (found.size != 1) {
            throw FixtureException(
                "the fixture is to be updated, a raw string `#\"…\"#` in a test, and it is in ${found.size} places " +
                    "under ${root}:\n${original}")
        }
        let (file, text, at) = found[0]
        File.writeTo(file, (text[..at] + replacement + text[at + original.size..]).toArray())
    }
}

/**
 * Where `content` starts in `text` as a whole raw string, between `#"` and `"#`.
 */
func rawStringsOf(text: String, content: String): Array<Int64> {
    let found = ArrayList<Int64>()
    var from = 0
    while (let Some(opening) <- text.indexOf("\"" + content + "\"", from)) {
        let start = opening + 1
        let end = start + content.size
        if (opening > 0 && text[opening - 1] == b'#' && end + 1 < text.size && text[end + 1] == b'#') {
            found.add(start)
        }
        from = start
    }
    found.toArray()
}

/**
 * The `*_test.cj` files under `dir`, but in hidden directories and `target`.
 */
func testsUnder(dir: Path): Array<Path> {
    let found = ArrayList<Path>()
    for (entry in Directory.readFrom(dir) where !entry.isSymbolicLink()) {
        let name = entry.name
        if (entry.isDirectory()) {
            if (!name.startsWith(".") && name != "target") {
                found.add(all: testsUnder(entry.path))
            }
        } else if (name.endsWith("_test.cj")) {
            found.add(entry.path)
        }
    }
    found.toArray()
}
