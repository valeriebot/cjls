package loupe.fixture

import std.collection.*
import std.env.getTempDirectory
import std.sort.*
import ginkgo.TextRange
import rope.Rope
import loupe.vfs.*
import loupe.db.*

/**
 * A fixture that does not say what it means: a header of an unknown key, a `$0` too many, an
 * annotation under nothing.
 */
public class FixtureException <: Exception {
    public init(message: String) {
        super(message)
    }

    protected override func getClassName(): String {
        "FixtureException"
    }
}

/**
 * A file of a fixture: where it is, the module and the package it is of, and its text, the markers
 * and the annotations taken out.
 */
public class FixtureFile {
    FixtureFile(
        public let fileId: FileId,
        public let path: VfsPath,
        public let module: String,
        public let pkg: String,
        public let deps: Array<String>,
        public let text: String,
        /**
         * Its header as written, `None` for the one file of a fixture of no header.
         */
        let header: ?String,
        /**
         * Its lines as written, `$0`s in them, the annotations left out.
         */
        let lines: Array<FixtureLine>
    ) {}
}

/**
 * A line of a file as written: its text, `$0`s in it, its offset in the file's text, and the
 * columns its `$0`s are at, as written.
 */
struct FixtureLine {
    FixtureLine(let written: String, let start: Int64, let markers: Array<Int64>) {}

    /**
     * The offset in the text of a column as written: past the end of the line, the columns go on
     * over its line break.
     */
    func offsetOf(column: Int64, end!: Bool): Int64 {
        let shift = 2 * markers.iterator().filter {marker => if (end) {
            marker + 2 <= column
        } else {
            marker < column
        }}.count()
        let clean = column - shift
        let runes = written.replace("$0", "").toRuneArray()
        if (clean <= runes.size) {
            start + String(runes[..clean]).size
        } else {
            start + String(runes).size + clean - runes.size
        }
    }

    /**
     * The column as written of an offset in the text, the inverse of `offsetOf`.
     */
    func columnOf(offset: Int64, end!: Bool): Int64 {
        let clean = written.replace("$0", "")
        let inLine = offset - start
        let column = if (inLine <= clean.size) {
            String.fromUtf8(clean.toArray()[..inLine]).toRuneArray().size
        } else {
            clean.toRuneArray().size + inLine - clean.size
        }
        var shifted = column
        for (marker in markers) {
            let before = if (end) {
                marker < shifted
            } else {
                marker <= shifted
            }
            if (before) {
                shifted += 2
            }
        }
        shifted
    }
}

/**
 * An expected answer, under the line it is about: `//^^^ text` for the range of the carets, `//|
 * text` for the empty one before the bar.
 */
public struct Annotation <: Equatable<Annotation> & ToString {
    public Annotation(public let fileId: FileId, public let range: TextRange, public let text: String) {}

    public operator func ==(other: Annotation): Bool {
        fileId.index == other.fileId.index && range == other.range && text == other.text
    }

    public operator func !=(other: Annotation): Bool {
        !(this == other)
    }

    public func toString(): String {
        "${fileId} ${range} ${text}"
    }
}

/**
 * A place in a file of a fixture.
 */
public struct FilePosition {
    public FilePosition(public let fileId: FileId, public let offset: Int64) {}
}

/**
 * A range of a file of a fixture.
 */
public struct FileRange {
    public FileRange(public let fileId: FileId, public let range: TextRange) {}
}

/**
 * Files, a place in them and the answers expected there, as one text: what a test of the analysis
 * sets the database to.
 *
 * ```
 * //- /src/a.cj module=app package=app.a
 * package app.a
 * public func foo() {}
 * //- /src/b.cj module=app package=app.b deps=lib
 * package app.b
 * main() { fo$0o() }
 *        //^^^^^ text
 * ```
 *
 * - The text is indented as a test writes it: a first empty line is left out, as is the indent of
 *   every line and the spaces of a last line of no more.
 * - A header `//- /path key=value…` starts a file: its path from the root of the fixture,
 *   `module` (`default` if not given), `package` (the module's name if not given) and `deps`
 *   (the modules it may import, by commas; a module's are those of all its files). A text of no
 *   header is the one file `/main.cj`.
 * - `$0` is a place, two of them in one file a range: the `cursor`, the `selection`.
 * - A line `//` and carets is an annotation: `//^^^ text` is about the range of the carets in the
 *   line above it that is not one, `//| text` about the empty range before the bar. Columns are as
 *   written, the `//` included: a range from the first two columns of a line is annotated when
 *   the file's code is indented by two.
 */
public class Fixture {
    private Fixture(
        public let files: Array<FixtureFile>,
        public let annotations: Array<Annotation>,
        private let markers: Array<FilePosition>,
        private let paths: PathInterner
    ) {}

    /**
     * The place of the one `$0`, `None` if there is none or there are two.
     */
    public prop cursor: ?FilePosition {
        get() {
            if (markers.size == 1) {
                markers[0]
            } else {
                None
            }
        }
    }

    /**
     * The range between the two `$0`s, `None` if there are not two.
     */
    public prop selection: ?FileRange {
        get() {
            if (markers.size == 2) {
                FileRange(markers[0].fileId, TextRange(markers[0].offset, markers[1].offset))
            } else {
                None
            }
        }
    }

    /**
     * @throws FixtureException - if `text` is not a fixture
     */
    public static func parse(text: String): Fixture {
        let lines = trimIndent(text).split("\n")
        // a text ending with a line break has an empty piece after it, not a line of its own
        let count = if (lines[lines.size - 1].isEmpty()) {
            lines.size - 1
        } else {
            lines.size
        }
        // the last line of the text keeps its line break only if the text had one
        let broken = count < lines.size
        let paths = PathInterner()
        let files = ArrayList<FixtureFile>()
        let annotations = ArrayList<Annotation>()
        let markers = ArrayList<FilePosition>()
        if (count == 0 || !isHeader(lines[0])) {
            files.add(parseFile(None, lines[..count], broken, paths, annotations, markers))
        } else {
            var first = 0
            while (first < count) {
                var last = first + 1
                while (last < count && !isHeader(lines[last])) {
                    last++
                }
                files.add(parseFile(lines[first], lines[first + 1..last], last < count || broken, paths, annotations,
                    markers))
                first = last
            }
        }
        if (markers.size > 2 || markers.size == 2 && markers[0].fileId.index != markers[1].fileId.index) {
            throw FixtureException("a fixture has one `$0`, or two in one file: ${markers.size} found")
        }
        Fixture(files.toArray(), annotations.toArray(), markers.toArray(), paths)
    }

    /**
     * The file at `path` of the fixture, as a header names it (`/src/a.cj`).
     *
     * @throws FixtureException - if the fixture has none there
     */
    public func file(path: String): FixtureFile {
        let wanted = pathOf(path)
        for (file in files where file.path == wanted) {
            return file
        }
        throw FixtureException("no file ${path} in the fixture")
    }

    /**
     * The modules and the packages of the files, each in the order it first comes in, a module's
     * root the deepest directory all its files are under.
     */
    public func projectModel(): ProjectModel {
        let modules = ArrayList<String>()
        for (file in files where !modules.contains(file.module)) {
            modules.add(file.module)
        }
        ProjectModel(Cfg([]), modules.toArray().map {name => moduleModel(name)})
    }

    /**
     * A database of the project and the texts of the files.
     */
    public func database(): AnalysisDatabase {
        let db = AnalysisDatabase()
        db.setProject(projectModel(), paths)
        for (file in files) {
            db.setFileText(file.fileId, Rope(file.text))
        }
        db
    }

    /**
     * The fixture as written, with `annotations` in place of its own, each under the line its
     * range starts in, those under one line in the order of their ranges and texts.
     *
     * @throws FixtureException - if a range is across lines, or starts in the first two columns
     * of a line, where no `//` can stand under it
     */
    public func render(annotations: Array<Annotation>): String {
        let out = StringBuilder()
        for (file in files) {
            if (let Some(header) <- file.header) {
                out.append(header)
                out.append("\n")
            }
            let under = Array<ArrayList<(Int64, Int64, String)>>(file.lines.size) {_ => ArrayList()}
            for (annotation in annotations where annotation.fileId.index == file.fileId.index) {
                let line = lineOf(file, annotation.range.start)
                let at = file.lines[line]
                let start = at.columnOf(annotation.range.start, end: false)
                let end = at.columnOf(annotation.range.end, end: true)
                if (annotation.range.end > lineEnd(file, line) || annotation.range.end < annotation.range.start) {
                    throw FixtureException("${annotation.range} is across lines of ${file.path}: ${annotation.text}")
                }
                if (start < 2) {
                    throw FixtureException(
                        "${annotation.range} starts at column ${start} of `${at.written}` in ${file.path}, left of " +
                            "where `//` lets an annotation start: indent the file's code by two")
                }
                under[line].add((start, end, annotation.text))
            }
            for (i in 0..file.lines.size) {
                let line = file.lines[i]
                out.append(line.written)
                if (i < file.lines.size - 1 || file.text.endsWith("\n")) {
                    out.append("\n")
                }
                let sorted = under[i].toArray()
                sort(sorted, by: {a: (Int64, Int64, String), b: (Int64, Int64, String) =>
                    if (a[0] != b[0]) {
                        a[0].compare(b[0])
                    } else if (a[1] != b[1]) {
                        a[1].compare(b[1])
                    } else {
                        a[2].compare(b[2])
                    }})
                for ((start, end, text) in sorted) {
                    if (!out.toString().endsWith("\n")) {
                        out.append("\n")
                    }
                    out.append("//")
                    out.append(" " * (start - 2))
                    if (end == start) {
                        out.append("|")
                    } else {
                        out.append("^" * (end - start))
                    }
                    if (!text.isEmpty()) {
                        out.append(" ")
                        out.append(text)
                    }
                    out.append("\n")
                }
            }
        }
        out.toString()
    }

    private func moduleModel(name: String): ModuleModel {
        let ofModule = files.filter {file => file.module == name}
        let packages = ArrayList<String>()
        let deps = ArrayList<String>()
        for (file in ofModule) {
            if (!packages.contains(file.pkg)) {
                packages.add(file.pkg)
            }
            for (dep in file.deps where !deps.contains(dep)) {
                deps.add(dep)
            }
        }
        var root = ofModule[0].path.parent.getOrThrow()
        for (file in ofModule) {
            while (!file.path.isUnder(root)) {
                root = root.parent.getOrThrow()
            }
        }
        ModuleModel(name, root, packages.toArray().map {
            pkg =>
            let ofPackage = ofModule.filter {file => file.pkg == pkg}
            PackageModel(pkg, ofPackage[0].path.parent.getOrThrow(), ofPackage.map {file => file.path})
        }, deps: deps.toArray())
    }
}

let ROOT = VfsPath.file(getTempDirectory()).join("fixture")

/**
 * Where a path of a fixture (`/src/a.cj`) is: under a directory of its own in the temporary one,
 * absolute on every platform.
 */
func pathOf(path: String): VfsPath {
    if (!path.startsWith("/")) {
        throw FixtureException("a path of a fixture starts with `/`: ${path}")
    }
    var result = ROOT
    for (name in path.split("/", removeEmpty: true)) {
        result = result.join(name)
    }
    result
}

func isHeader(line: String): Bool {
    line.startsWith("//-")
}

/**
 * Whether the line is an annotation: `//`, spaces, and carets or a bar.
 */
func annotationMarker(line: String): ?(Int64, Int64, String) {
    let trimmed = line.trimAsciiStart()
    if (!trimmed.startsWith("//")) {
        return None
    }
    let afterSlashes = trimmed[2..].trimAsciiStart()
    let column = line.toRuneArray().size - afterSlashes.toRuneArray().size
    if (afterSlashes.startsWith("|")) {
        return (column, 0, afterSlashes[1..].trimAscii())
    }
    var carets = 0
    while (carets < afterSlashes.size && afterSlashes[carets] == b'^') {
        carets++
    }
    if (carets == 0) {
        return None
    }
    (column, carets, afterSlashes[carets..].trimAscii())
}

func parseFile(header: ?String, body: Array<String>, broken: Bool, paths: PathInterner,
    annotations: ArrayList<Annotation>, markers: ArrayList<FilePosition>): FixtureFile {
    var path = "/main.cj"
    var module = "default"
    var pkg: ?String = None
    var deps = Array<String>()
    if (let Some(line) <- header) {
        let words = line[3..].split(" ", removeEmpty: true)
        if (words.size == 0) {
            throw FixtureException("a header names no path: ${line}")
        }
        path = words[0]
        for (word in words[1..]) {
            let pair = word.split("=", 2)
            if (pair.size != 2) {
                throw FixtureException("not a `key=value`: ${word} in ${line}")
            }
            match (pair[0]) {
                case "module" => module = pair[1]
                case "package" => pkg = pair[1]
                case "deps" => deps = pair[1].split(",", removeEmpty: true)
                case key => throw FixtureException("an unknown key `${key}` in ${line}: module, package, deps")
            }
        }
    }
    let vfsPath = pathOf(path)
    if (paths.lookup(vfsPath).isSome()) {
        throw FixtureException("two files at ${path}")
    }
    let fileId = paths.intern(vfsPath)
    let text = StringBuilder()
    let lines = ArrayList<FixtureLine>()
    for (i in 0..body.size) {
        let line = body[i]
        if (let Some((column, len, note)) <- annotationMarker(line)) {
            if (lines.size == 0) {
                throw FixtureException("an annotation under no line of ${path}: ${line}")
            }
            let above = lines[lines.size - 1]
            let start = above.offsetOf(column, end: false)
            let end = above.offsetOf(column + len, end: true)
            annotations.add(Annotation(fileId, TextRange(start, end), note))
            continue
        }
        let start = text.size
        let columns = ArrayList<Int64>()
        let runes = line.toRuneArray()
        var clean = StringBuilder()
        var j = 0
        while (j < runes.size) {
            if (runes[j] == r'$' && j + 1 < runes.size && runes[j + 1] == r'0') {
                columns.add(j)
                markers.add(FilePosition(fileId, start + clean.size))
                j += 2
            } else {
                clean.append(runes[j])
                j++
            }
        }
        text.append(clean.toString())
        if (i < body.size - 1 || broken) {
            text.append("\n")
        }
        lines.add(FixtureLine(line, start, columns.toArray()))
    }
    FixtureFile(fileId, vfsPath, module, pkg ?? module, deps, text.toString(), header, lines.toArray())
}

/**
 * The line an offset of the file is in: past the last line break, the line before it.
 */
func lineOf(file: FixtureFile, offset: Int64): Int64 {
    var line = 0
    for (i in 0..file.lines.size where file.lines[i].start <= offset) {
        line = i
    }
    if (line > 0 && file.lines[line].start == offset && offset == file.text.size) {
        line - 1
    } else {
        line
    }
}

/**
 * The offset of the end of a line, its line break included.
 */
func lineEnd(file: FixtureFile, line: Int64): Int64 {
    if (line + 1 < file.lines.size) {
        file.lines[line + 1].start
    } else {
        file.text.size
    }
}

/**
 * The text as a test writes it, unindented: a first empty line left out, as are the indent all
 * lines share and the spaces of a last line of nothing else.
 */
public func trimIndent(text: String): String {
    let body = splitIndent(text)[1]
    let indent = commonIndent(body)
    let lines = body.split("\n").map {line => if (line.trimAscii().isEmpty()) {
        ""
    } else {
        line[indent..]
    }}
    String.join(lines, delimiter: "\n")
}

/**
 * `text` as the first empty line, the lines, and the spaces of the last line of nothing else.
 */
func splitIndent(text: String): (String, String, String) {
    let lead = if (text.startsWith("\n")) {
        "\n"
    } else {
        ""
    }
    let rest = text[lead.size..]
    let lastBreak = rest.lastIndexOf("\n")
    if (let Some(at) <- lastBreak) {
        let last = rest[at + 1..]
        if (last.trimAscii().isEmpty()) {
            return (lead, rest[..at + 1], last)
        }
    }
    (lead, rest, "")
}

func commonIndent(body: String): Int64 {
    var indent = Int64.Max
    for (line in body.split("\n") where !line.trimAscii().isEmpty()) {
        var spaces = 0
        while (spaces < line.size && (line[spaces] == b' ' || line[spaces] == b'\t')) {
            spaces++
        }
        indent = min(indent, spaces)
    }
    if (indent == Int64.Max) {
        0
    } else {
        indent
    }
}

/**
 * `rendered`, an unindented fixture, indented as `original` is: what replaces it in a test.
 */
public func indentLike(original: String, rendered: String): String {
    let (lead, body, tail) = splitIndent(original)
    let prefix = body.split("\n").iterator().filter {line => !line.trimAscii().isEmpty()}.next().map {
        line => line[..commonIndent(body)]
    } ?? ""
    let lines = rendered.split("\n")
    let out = StringBuilder(lead)
    for (i in 0..lines.size) {
        let line = lines[i]
        if (i == lines.size - 1 && line.isEmpty()) {
            break
        }
        if (i > 0) {
            out.append("\n")
        }
        if (!line.isEmpty()) {
            out.append(prefix)
            out.append(line)
        }
    }
    if (rendered.endsWith("\n")) {
        out.append("\n")
        out.append(tail)
    }
    out.toString()
}
