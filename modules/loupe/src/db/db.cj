package loupe.db

import std.collection.{ArrayList, collectArray, filter, HashMap, HashSet}
import std.collection.concurrent.ConcurrentHashMap
import calca.*
import calca.macros.*
import rope.Rope
import loupe.vfs.*

/**
 * One file's text as the analysis sees it. The database keeps one per `FileId`, made the first time
 * the file is set, and never drops it: a file deleted is an empty text (A5).
 */
@CalcaInput
public struct SourceFile {
    public let fileId: FileId
    public var text: Rope
}

/**
 * The analysis database: `AnalysisDatabase()` makes one and its root handle, `snapshot` another
 * handle for another thread. See calca's `Storage`.
 *
 * Every query takes this class itself, whatever layer it is in, with no interface of its own in
 * between: calca keeps the state of every query in `storage`, so the class need know none of them,
 * and can sit under all of them.
 */
public class AnalysisDatabase <: Database {
    private AnalysisDatabase(private let storage_: Storage, private let files: Files, private let projects: Projects) {}

    public init() {
        this(Storage(), Files(), Projects())
    }

    public prop storage: Storage {
        get() {
            storage_
        }
    }

    /**
     * Its queries throw `CancelledException` once `cancelledBy` gives `true`, as well as once the
     * files change.
     */
    public func snapshot(cancelledBy!: () -> Bool = {=> false}): AnalysisDatabase {
        AnalysisDatabase(storage_.snapshot(cancelledBy: cancelledBy), files, projects)
    }

    /**
     * The file's input, `None` for a file never set.
     */
    public func sourceFile(fileId: FileId): ?SourceFile {
        files.get(fileId)
    }

    /**
     * Sets the file's text, in a revision of its own, making its input the first time.
     *
     * @throws IllegalStateException - if this is a snapshot, or a query is running on it
     */
    public func setFileText(fileId: FileId, text: Rope, durability!: Durability = Durability.Low): SourceFile {
        match (files.get(fileId)) {
            case Some(file) =>
                file.setText(this).withDurability(durability).to(text)
                file
            case None =>
                let file = SourceFile(this, fileId, text, durability: durability)
                files.add(fileId, file)
                file
        }
    }

    /**
     * Brings the files in step with `changes`, taken from `vfs`, each with its module's durability:
     * `Low` for a file of no module.
     *
     * @throws IllegalStateException - if this is a snapshot, or a query is running on it
     */
    public func applyChanges(vfs: Vfs, changes: Array<ChangedFile>): Unit {
        batch {
            for (change in changes) {
                setFileText(change.fileId, vfs.fileContents(change.fileId) ?? Rope(),
                    durability: projects.durabilities.get(change.fileId) ?? Durability.Low)
            }
        }
    }

    /**
     * The project, `None` until one is set.
     */
    public func project(): ?Project {
        Project.tryGet(this)
    }

    /**
     * Sets the project to `model`, in one revision: a module is the input of its root and its
     * name, a package the input of its name in its module, made the first time, and only what differs
     * from what it was set to last is set again.
     * The files of a module set from now on take its durability; a file is given its id by
     * `paths`. A file set already keeps the durability it has until it changes.
     *
     * `binaries` are the packages of `model`'s binaries that were read: a `.cjo` is the input of
     * its binary, package and path, its bytes set only when they differ from the last; one read
     * before and not now holds no bytes.
     *
     * @throws IllegalStateException - if this is a snapshot, or a query is running on it
     */
    public func setProject(model: ProjectModel, paths: PathInterner, binaries!: Array<CjoFileRead> = []): Unit {
        let durabilities = HashMap<FileId, Durability>()
        batch {
            let modules = model.modules.map {module => setModule(module, paths, durabilities)}
            let packages = setBinaryPackages(binaries)
            match (projects.project) {
                case None => projects.project = (Project(this, model.cfg, modules, model.binaries, packages,
                    durability: Durability.High), model.cfg, modules, model.binaries, packages)
                case Some((project, cfg, oldModules, oldBinaries, oldPackages)) =>
                    if (cfg != model.cfg) {
                        project.setCfg(this).withDurability(Durability.High).to(model.cfg)
                    }
                    if (oldModules != modules) {
                        project.setModules(this).withDurability(Durability.High).to(modules)
                    }
                    if (oldBinaries != model.binaries) {
                        project.setBinaries(this).withDurability(Durability.High).to(model.binaries)
                    }
                    if (oldPackages != packages) {
                        project.setBinaryPackages(this).withDurability(Durability.High).to(packages)
                    }
                    projects.project = (project, model.cfg, modules, model.binaries, packages)
            }
        }
        projects.durabilities = durabilities
    }

    /**
     * The stamp of the `.cjo` `file` was set with, `None` if it holds no bytes: whether it needs to
     * be read again.
     */
    public func binaryStamp(file: CjoFile): ?FileStamp {
        projects.binaries.get(file).flatMap {binary => binary[1]}
    }

    private func setBinaryPackages(reads: Array<CjoFileRead>): Array<BinaryPackageFile> {
        let kept = HashSet<CjoFile>()
        let packages = ArrayList<BinaryPackageFile>()
        for (read in reads) {
            let durability = binaryDurability(read.file.binary)
            match ((projects.binaries.get(read.file), read.bytes)) {
                case (Some((pkg, _, old)), Some(bytes)) =>
                    if (bytes != old) {
                        pkg.setBytes(this).withDurability(durability).to(bytes)
                    }
                    projects.binaries.add(read.file, (pkg, read.stamp, bytes))
                    packages.add(pkg)
                case (Some((pkg, Some(_), _)), None) => packages.add(pkg)
                case (None, Some(bytes)) =>
                    let pkg = BinaryPackageFile(this, read.file.binary, read.file.name, read.file.path, bytes,
                        durability: durability)
                    projects.binaries.add(read.file, (pkg, read.stamp, bytes))
                    packages.add(pkg)
                // left unread, but nothing was read before
                case _ => continue
            }
            kept.add(read.file)
        }
        let gone = projects.binaries.keys() |> filter {file: CjoFile => !kept.contains(file)} |> collectArray
        for (file in gone) {
            let (pkg, stamp, _) = projects.binaries[file]
            if (stamp.isSome()) {
                pkg.setBytes(this).withDurability(binaryDurability(file.binary)).to([])
                projects.binaries.add(file, (pkg, None, []))
            }
        }
        packages.toArray()
    }

    private func setModule(model: ModuleModel, paths: PathInterner, durabilities: HashMap<FileId, Durability>): Module {
        let durability = model.durability
        let packages = model.packages.map {
            pkg =>
            let files = pkg.files.map {path => paths.intern(path)}
            for (file in files) {
                durabilities.add(file, durability)
            }
            setPackage(model.key, pkg, files, durability)
        }
        match (projects.modules.get(model.key)) {
            case Some((module, old)) =>
                // a package is the input of its name in this module: the same names are the same inputs
                if (old.packages.map {it => it.name} != model.packages.map {it => it.name} || old.durability != durability) {
                    module.setPackages(this).withDurability(durability).to(packages)
                }
                if (old.deps != model.deps || old.durability != durability) {
                    module.setDeps(this).withDurability(durability).to(model.deps)
                }
                if (old.member != model.member) {
                    module.setMember(this).withDurability(durability).to(model.member)
                }
                if (old.cfg != model.cfg || old.durability != durability) {
                    module.setCfg(this).withDurability(durability).to(model.cfg)
                }
                projects.modules.add(model.key, (module, model))
                module
            case None =>
                let module = Module(this, model.root, model.name, packages, model.deps, model.member, model.cfg,
                    durability: durability)
                projects.modules.add(model.key, (module, model))
                module
        }
    }

    private func setPackage(module: ModuleKey, model: PackageModel, files: Array<FileId>, durability: Durability): Package {
        let key = PackageKey(module, model.name)
        match (projects.packages.get(key)) {
            case Some((pkg, old, oldDurability)) =>
                let moved = oldDurability != durability
                if (old.dir != model.dir || moved) {
                    pkg.setDir(this).withDurability(durability).to(model.dir)
                }
                if (old.files != model.files || moved) {
                    pkg.setFiles(this).withDurability(durability).to(files)
                }
                if (old.noPrelude != model.noPrelude || moved) {
                    pkg.setNoPrelude(this).withDurability(durability).to(model.noPrelude)
                }
                if (old.isMacro != model.isMacro || moved) {
                    pkg.setIsMacro(this).withDurability(durability).to(model.isMacro)
                }
                projects.packages.add(key, (pkg, model, durability))
                pkg
            case None =>
                let pkg = Package(this, model.name, model.dir, files, model.noPrelude, model.isMacro,
                    durability: durability)
                projects.packages.add(key, (pkg, model, durability))
                pkg
        }
    }

    /**
     * Makes every change `change` makes to the files one revision: the snapshots are cancelled
     * once, and what is in flight waited for once. Nothing is read inside it.
     *
     * @throws IllegalStateException - if this is a snapshot, or a query is running on it, or
     * `change` reads
     */
    public func batch<T>(change: () -> T): T {
        storage_.batch(change)
    }
}

/**
 * The input of every file, by id, shared by a database and its snapshots.
 */
class Files {
    private let byId = ConcurrentHashMap<FileId, SourceFile>()

    func get(fileId: FileId): ?SourceFile {
        byId.get(fileId)
    }

    func add(fileId: FileId, file: SourceFile): Unit {
        byId.add(fileId, file)
    }
}
