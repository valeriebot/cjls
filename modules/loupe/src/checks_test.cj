package loupe

import std.collection.*
import loupe.fixture.*

/**
 * Checks the diagnostics of every file of `fixture` are its annotations, `//^^^ error: message`.
 */
func checkDiagnostics(fixture: String): Unit {
    let parsed = Fixture.parse(fixture)
    let db = parsed.database()
    let actual = ArrayList<Annotation>()
    for (file in parsed.files) {
        actual.add(all: diagnostics(db, file.fileId).map {
            diagnostic =>
            let severity = match (diagnostic.severity) {
                case Error => "error"
            }
            Annotation(file.fileId, diagnostic.range, "${severity}: ${diagnostic.message}")
        })
    }
    expectAnnotations(fixture, actual.toArray())
}

/**
 * Checks the declarations a search of the files of `fixture` for `query` finds are its annotations,
 * under their names: `//^^^ Function in A`, the kind and the declaration it is in.
 */
func checkSymbols(fixture: String, query: String): Unit {
    let parsed = Fixture.parse(fixture)
    let found = workspaceSymbols(parsed.database(), parsed.files.map {file => file.fileId}, query, Int64.Max)
    expectAnnotations(fixture, found.map {
        found =>
        let container = match (found.symbol.containerName) {
            case Some(name) => " in ${name}"
            case None => ""
        }
        Annotation(found.fileId, found.symbol.selectionRange, "${found.symbol.kind}${container}")
    })
}
