package calca

import std.collection.*

/**
 * What a database is to the code `@CalcaInput`, `@CalcaInterned` and `@CalcaTracked` generate:
 * something that hands out its `Storage`. A project declares its own interface on top of it, for
 * the tracked functions to take, and a class implementing that:
 *
 * ```cangjie
 * public interface Db <: Database {}
 *
 * public class RootDatabase <: Db {
 *     private RootDatabase(private let storage_: Storage) {}
 *     public init() { this(Storage()) }
 *     public prop storage: Storage { get() { storage_ } }
 *     public func snapshot(): RootDatabase { RootDatabase(storage_.snapshot()) }
 * }
 * ```
 */
public interface Database {
    prop storage: Storage

    /**
     * Throws `CancelledException` if a write is pending, or this is a snapshot of a revision gone
     * by. Every query already checks; this is for long computations of one's own between them.
     */
    func unwindIfCancelled(): Unit {
        storage.unwindIfCancelled()
    }
}

/**
 * One handle of a database: the state all handles share, and what this one is computing. A handle
 * is used from one thread at a time.
 *
 * `Storage()` makes a database and its root handle, which always reads the current revision and is
 * the only one that changes inputs. `snapshot` gives another thread a handle pinned to the revision
 * current when it was taken. Changing an input cancels what is in flight on the snapshots and waits
 * for that to end, never for a snapshot as such: one used after it simply throws
 * `CancelledException`, so there is nothing to close, and a snapshot forgotten holds up nothing.
 */
public class Storage {
    private Storage(
        let runtime: Runtime,
        /**
         * The revision of a snapshot, `None` for the root handle.
         */
        private let pinned: ?Int64,
        /**
         * Whoever uses a snapshot asking it to stop: checked with every operation, as a write is.
         */
        private let cancelledBy: () -> Bool
    ) {
        handle = runtime.newHandle()
    }

    /**
     * This handle among the others of the database, as the claims on memos name it.
     */
    let handle: Int64

    private let stack = ArrayList<ActiveQuery>()
    /**
     * The keys this handle works on, each with how many queries were executing as it began.
     */
    private let active = HashMap<DatabaseKey, Int64>()

    /**
     * How many operations of this handle are nested in one another: only the outermost one goes
     * through the gate.
     */
    private var depth: Int64 = 0

    public init() {
        this(Runtime(), None, {=> false})
    }

    /**
     * Another handle of the same database, for another thread, pinned to the revision this one
     * reads. Its queries throw `CancelledException` too once `cancelledBy` gives `true`: how
     * whoever asked for the answer (an editor's `$/cancelRequest`) stops a computation of it midway.
     */
    public func snapshot(cancelledBy!: () -> Bool = {=> false}): Storage {
        Storage(runtime, pinned ?? runtime.revision, cancelledBy)
    }

    /**
     * @throws CancelledException - if a write is pending, this is a snapshot of a revision gone by,
     * or it was asked to stop
     */
    @Frozen
    public func unwindIfCancelled(): Unit {
        checkAskedToStop()
        if (runtime.isCancelled(pinned)) {
            throw unwinding(CancelledException())
        }
    }

    /**
     * Runs one operation of this handle, which a write waits for if it is not inside another.
     *
     * @throws CancelledException - if a write is pending, this is a snapshot of a revision gone by,
     * or it was asked to stop
     */
    @Frozen
    func read<T>(operation: () -> T): T {
        let outermost = beginOperation()
        try {
            operation()
        } finally {
            endOperation(outermost)
        }
    }

    /**
     * `read` without a closure, for what a hit goes through: whether the operation is the
     * outermost one goes to `endOperation`, in a `finally`.
     */
    @Frozen
    func beginOperation(): Bool {
        if (batching.isSome()) {
            // a memo computed now would be current in a revision the rest of the batch changes
            throw IllegalStateException("nothing is read inside a batch, which only changes inputs")
        }
        checkAskedToStop()
        let outermost = depth == 0
        if (outermost) {
            runtime.beginRead(pinned)
        } else if (runtime.isCancelled(pinned)) {
            throw unwinding(CancelledException())
        }
        depth++
        outermost
    }

    @Frozen
    func endOperation(outermost: Bool): Unit {
        depth--
        if (outermost) {
            runtime.endRead()
        }
    }

    @Frozen
    private func checkAskedToStop(): Unit {
        if (cancelledBy()) {
            throw unwinding(CancelledException())
        }
    }

    /**
     * Makes `change` in a new revision, once what is in flight on the snapshots has ended.
     *
     * @throws IllegalStateException - if this is a snapshot, or the handle is inside an operation
     */
    func write<T>(change: (Int64) -> T): T {
        if (let Some(revision) <- batching) {
            return change(revision)
        }
        checkWritable("change")
        runtime.write(change)
    }

    /**
     * The revision of the batch this handle is inside, `None` outside any.
     */
    var batching: ?Int64 = None

    /**
     * Makes every input `change` sets or creates in one revision: waits for what is in flight once,
     * and cancels the snapshots once. Inside it, nothing is read. A batch inside a batch is part of
     * it. If `change` throws, what it changed until then stays changed, in that revision.
     *
     * @throws IllegalStateException - if this is a snapshot, or the handle is inside an operation,
     * or `change` reads
     */
    public func batch<T>(change: () -> T): T {
        if (batching.isSome()) {
            return change()
        }
        checkWritable("change")
        runtime.write {
            revision =>
            batching = revision
            try {
                change()
            } finally {
                batching = None
            }
        }
    }

    /**
     * Refuses to `action` an input from a snapshot, or inside an operation: only the root handle
     * makes inputs, and what a query computes depends on nothing but what it reads.
     *
     * @throws IllegalStateException - if this is a snapshot, or the handle is inside an operation
     */
    func checkWritable(action: String): Unit {
        if (pinned.isSome()) {
            throw IllegalStateException("a snapshot cannot ${action} an input")
        }
        if (depth > 0) {
            throw IllegalStateException("an input cannot ${action} while a query runs")
        }
    }

    /**
     * Marks `key` as being worked on by this handle until `exit`, verified or executed alike.
     *
     * If it already is, and is executing, the queries executing since are a cycle. When every one of
     * them has a fallback, each is marked to take it, and depends on everything any of them read:
     * the one asking unwinds at once, the others at their next read. When `key` is only being
     * verified, whoever verifies it is told to execute it instead, which finds the cycle as above.
     *
     * @throws CycleException - if it already is, and a query on the cycle has no fallback
     */
    func enter(key: DatabaseKey): Unit {
        let entered = match (active.get(key)) {
            case Some(depth) => depth
            case None =>
                active.add(key, stack.size)
                return
        }
        if (entered >= stack.size || stack[entered].key != key) {
            throw unwinding(VerifyingCycleException(key), from: entered)
        }
        let participants = stack.toArray()[entered..]
        if (!participants.iterator().all {frame => runtime.ingredientAt(frame.key.ingredient).hasFallback()}) {
            let path = participants.map {frame => describe(frame.key)}
            let closed = ArrayList<String>(path)
            closed.add(describe(key))
            throw CycleException("cycle: ${String.join(closed.toArray(), delimiter: " -> ")}", path)
        }
        let cycle = HashSet<DatabaseKey>(participants.map {frame => frame.key})
        let union = ActiveQuery(key)
        for (frame in participants) {
            union.absorb(frame, cycle)
        }
        for (frame in participants) {
            frame.enterCycle(union, cycle)
        }
        throw CycleUnwindException()
    }

    /**
     * Waits, having given way on a loop of handles waiting for one another, for the handle given way
     * to to let go of what this one waited for.
     *
     * @throws CancelledException - if a write is pending, this is a snapshot of a revision gone by,
     * or it was asked to stop
     */
    func giveWay(): Unit {
        runtime.giveWay(handle) {=> unwindIfCancelled()}
    }

    /**
     * Marks the queries executing from the `from`th on as unwound by `e`, about to be thrown, and
     * gives it: one whose body catches it and returns stores no memo, and throws it on (`execute`).
     * A query that begins after it is not marked, nor is one below `from`, where it is caught.
     */
    func unwinding<E>(e: E, from!: Int64 = 0): E where E <: Exception {
        for (frame in stack.toArray()[from..]) {
            frame.unwoundBy = e
        }
        e
    }

    /**
     * `unwinding` for a `GiveWayException`, which unwinds to whoever claimed its key on this handle.
     */
    func givingWay(e: GiveWayException): GiveWayException {
        unwinding(e, from: active.get(e.key) ?? 0)
    }

    func exit(key: DatabaseKey): Unit {
        active.remove(key)
    }

    func push(key: DatabaseKey): ActiveQuery {
        let frame = ActiveQuery(key)
        stack.add(frame)
        frame
    }

    func pop(): Unit {
        stack.remove(at: stack.size - 1)
    }

    /**
     * Records a read on the query running, if any.
     */
    @Frozen
    func reportRead(key: DatabaseKey, durability: Durability, changedAt: Int64): Unit {
        if (let Some(frame) <- stack.last) {
            frame.read(key, durability, changedAt)
            if (frame.unwinding) {
                // a query on a recovered cycle: it takes its fallback, whatever it would compute
                throw CycleUnwindException()
            }
        }
    }

    /**
     * The lowest durability the query running has read so far, `None` outside any query. It only
     * falls as the query goes on.
     */
    prop queryDurability: ?Durability {
        get() {
            stack.last?.durability
        }
    }

    private func describe(key: DatabaseKey): String {
        runtime.ingredientAt(key.ingredient).describe(key.id)
    }
}

/**
 * What a query running has read so far.
 */
class ActiveQuery {
    ActiveQuery(let key: DatabaseKey) {}

    let dependencies = ArrayList<DatabaseKey>()
    private let seen = HashSet<DatabaseKey>()
    var durability = Durability.High
    var changedAt = FIRST_REVISION

    /**
     * On a cycle whose queries all take their fallback: until the fallback is computed, every read
     * unwinds.
     */
    var unwinding = false

    /**
     * On a cycle whose queries all take their fallback, the value is the fallback.
     */
    var inCycle = false

    /**
     * What unwinds the query, to a catch below it: its body catching that is no reason to keep
     * what it computes.
     */
    var unwoundBy: ?Exception = None

    func read(key: DatabaseKey, durability: Durability, changedAt: Int64): Unit {
        if (seen.add(key)) {
            dependencies.add(key)
        }
        this.durability = min(this.durability, durability)
        this.changedAt = max(this.changedAt, changedAt)
    }

    /**
     * Adds what `other` read, but the queries on `cycle`.
     */
    func absorb(other: ActiveQuery, cycle: HashSet<DatabaseKey>): Unit {
        for (key in other.dependencies where !cycle.contains(key)) {
            if (seen.add(key)) {
                dependencies.add(key)
            }
        }
        durability = min(durability, other.durability)
        changedAt = max(changedAt, other.changedAt)
    }

    /**
     * Makes this query one of a cycle recovered: it depends on what the whole cycle read, `union`,
     * and on none of the queries on it, whose values are all fallbacks.
     */
    func enterCycle(union: ActiveQuery, cycle: HashSet<DatabaseKey>): Unit {
        let kept = dependencies.toArray().filter {key => !cycle.contains(key)}
        dependencies.clear()
        seen.clear()
        for (key in kept) {
            seen.add(key)
            dependencies.add(key)
        }
        absorb(union, cycle)
        inCycle = true
        unwinding = true
    }
}
