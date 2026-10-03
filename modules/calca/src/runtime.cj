package calca

import std.collection.*
import std.sync.*

const FIRST_REVISION: Int64 = 1

let nextIngredient = AtomicInt64(0)

/**
 * Reserves `count` consecutive ingredient indices, process-wide, so the one index of an ingredient
 * names it in every database. Called once per `@CalcaInput` type and `@CalcaTracked` function, from the
 * static the macro gives it; the order of those calls decides only which numbers they get.
 */
func reserveIngredients(count: Int64): Int64 {
    nextIngredient.fetchAdd(count)
}

/**
 * The part of a database one input field or one tracked function keeps: its values, and how to
 * tell whether one of them changed.
 */
interface Ingredient {
    /**
     * Whether the value at `id` may have changed after `revision`. For a tracked function that may
     * mean verifying its memo, or executing it again, on `db`.
     */
    func maybeChangedAfter(db: Database, id: Id, revision: Int64): Bool

    func describe(id: Id): String

    /**
     * Whether a value on a cycle can be replaced by a fallback: a tracked function's `cycle` option.
     */
    func hasFallback(): Bool {
        false
    }

    /**
     * Called as a write opens a new revision, while nothing reads: when an ingredient lets go of
     * what it no longer needs.
     */
    func newRevision(): Unit {}
}

class IngredientTable {
    IngredientTable(let entries: Array<?Ingredient>) {}
}

/**
 * What every handle of one database shares: the revision, the ingredients, and the gate a write
 * goes through.
 */
class Runtime {
    private let revision_ = AtomicInt64(FIRST_REVISION)

    /**
     * For every durability, the last revision in which an input of at least that durability changed.
     */
    private let lastChanged = Array<AtomicInt64>(DURABILITIES, {_ => AtomicInt64(FIRST_REVISION)})

    /**
     * Copied on write, so the lookup every query makes takes no lock.
     */
    private let table = AtomicReference<IngredientTable>(IngredientTable([]))
    private let tableLock = Mutex()

    /**
     * What a write holds throughout, so writes go one at a time and the root handle waits for one
     * to end; an operation that begins meanwhile is cancelled. Readers count themselves in and out
     * without it.
     */
    private let gate = Mutex()

    /**
     * What a write waits for the count under, held only while it looks at the count: the last
     * reader out takes it to wake the write, never waiting for the change the write makes after.
     */
    private let drainLock = Mutex()
    private let drained: Condition
    private let inFlight = AtomicInt64(0)
    private let writePending = AtomicBool(false)

    /**
     * Which handle waits for which, and for what, while one waits for a memo another computes: a
     * wait that would close a loop gives way rather than deadlock.
     */
    private let waitLock = Mutex()
    private let waitsFor = HashMap<Int64, (Int64, DatabaseKey)>()

    /**
     * Notified as a claim goes, for a handle that gave way to another on a loop of waits.
     */
    private let waitReleased: Condition

    private let nextHandle = AtomicInt64(0)

    Runtime() {
        drainLock.lock()
        drained = drainLock.condition()
        drainLock.unlock()
        waitLock.lock()
        waitReleased = waitLock.condition()
        waitLock.unlock()
    }

    @Frozen
    prop revision: Int64 {
        get() {
            revision_.load()
        }
    }

    @Frozen
    func lastChangedAt(durability: Durability): Int64 {
        lastChanged[durability.rank].load()
    }

    @Frozen
    func ingredient<I>(index: Int64, create: () -> I): I where I <: Ingredient {
        let found = match (lookup(index)) {
            case Some(ingredient) => ingredient
            case None => synchronized(tableLock) {
                match (lookup(index)) {
                    case Some(ingredient) => ingredient
                    case None =>
                        let created = create()
                        register(index, created)
                        created
                }
            }
        }
        (found as I).getOrThrow {=> IllegalStateException("ingredient ${index} is ${found.describe(Id(0))}'s, of another type")}
    }

    /**
     * The ingredient at `index` if it was created, without a closure to create it.
     */
    @Frozen
    func existing<I>(index: Int64): ?I where I <: Ingredient {
        match (lookup(index)) {
            case Some(ingredient) => ingredient as I
            case None => None
        }
    }

    func ingredientAt(index: Int64): Ingredient {
        lookup(index).getOrThrow {=> IllegalStateException("no ingredient ${index} in this database")}
    }

    @Frozen
    private func lookup(index: Int64): ?Ingredient {
        table.load().entries.get(index) ?? None
    }

    private func register(index: Int64, ingredient: Ingredient): Unit {
        let entries = table.load().entries
        let grown = Array<?Ingredient>(max(entries.size, index + 1), {i => entries.get(i) ?? None})
        grown[index] = ingredient
        table.store(IngredientTable(grown))
    }

    /**
     * Begins an operation of a handle outside any query, which a write waits for.
     *
     * @throws CancelledException - if a write is pending, or the handle is pinned to a revision
     * gone by
     */
    @Frozen
    func beginRead(pinned: ?Int64): Unit {
        while (true) {
            // counted in before looking for a write: a write marks itself pending before it counts,
            // so one of the two sees the other
            inFlight.fetchAdd(1)
            if (!writePending.load()) {
                try {
                    unwindIfCancelled(pinned)
                } catch (e: CancelledException) {
                    endRead()
                    throw e
                }
                return
            }
            endRead()
            if (pinned.isSome()) {
                throw CancelledException()
            }
            // the root handle waits for the write to end, and reads the revision it opens
            synchronized(gate) {}
        }
    }

    @Frozen
    func endRead(): Unit {
        if (inFlight.fetchSub(1) == 1 && writePending.load()) {
            // the write looks at the count under the same lock, so it cannot miss this
            synchronized(drainLock) {
                drained.notifyAll()
            }
        }
    }

    /**
     * Cancels the operations in flight, waits for them to end, and makes `change` in a new
     * revision, which it is given. Holds the gate throughout, so nothing begins until it is done;
     * the ingredients let go of what they no longer need then, with nothing reading them.
     */
    func write<T>(change: (Int64) -> T): T {
        synchronized(gate) {
            writePending.store(true)
            try {
                synchronized(drainLock) {
                    while (inFlight.load() > 0) {
                        drained.wait()
                    }
                }
                for (ingredient in table.load().entries) {
                    ingredient?.newRevision()
                }
                change(revision_.fetchAdd(1) + 1)
            } finally {
                writePending.store(false)
            }
        }
    }

    /**
     * Records that an input of `durability` changed in `revision`, which makes every memo that read
     * inputs of that durability or a lower one verify its dependencies again.
     */
    func changed(durability: Durability, revision: Int64): Unit {
        for (rank in 0..=durability.rank) {
            lastChanged[rank].store(revision)
        }
    }

    /**
     * A number for a new handle, distinct from every other one's in this database.
     */
    func newHandle(): Int64 {
        nextHandle.fetchAdd(1)
    }

    /**
     * Records that handle `waiter` waits for `key`, which handle `owner` computes, until
     * `stopWaiting` or until the owner lets go of it. Waiting already, for the same, records nothing
     * again: a waiter that wakes to look whether it was asked to stop does not find again a loop it
     * was given way to.
     *
     * If `owner` waits, through others or not, for `waiter`, the waiter gives way: it waits for `key`
     * all the same, and is told which of its own queries the loop waits for, to unwind to it and let
     * go of it (`giveWay`).
     *
     * @throws GiveWayException - if `owner` waits, through others or not, for `waiter`
     */
    func startWaiting(waiter: Int64, owner: Int64, key: DatabaseKey): Unit {
        synchronized(waitLock) {
            if (let Some((known, awaited)) <- waitsFor.get(waiter)) {
                if (known == owner && awaited == key) {
                    return
                }
            }
            // a handle giving way waits for one on the loop until it lets go: a walk not reaching
            // the waiter in as many steps as there are edges went round a loop of others
            var current = owner
            for (_ in 0..=waitsFor.size) {
                let (next, awaited) = waitsFor.get(current) ?? break
                if (next == waiter) {
                    waitsFor.add(waiter, (owner, key))
                    throw GiveWayException(awaited)
                }
                current = next
            }
            waitsFor.add(waiter, (owner, key))
        }
    }

    func stopWaiting(waiter: Int64): Unit {
        synchronized(waitLock) {
            waitsFor.remove(waiter)
        }
    }

    /**
     * Whoever waited for `key` waits for its owner no more: it is free, whether or not the waiter
     * has woken to see it.
     */
    func released(key: DatabaseKey): Unit {
        synchronized(waitLock) {
            if (waitsFor.isEmpty()) {
                return
            }
            let freed = ArrayList<Int64>()
            for ((waiter, (_, awaited)) in waitsFor where awaited == key) {
                freed.add(waiter)
            }
            for (waiter in freed) {
                waitsFor.remove(waiter)
            }
            if (!freed.isEmpty()) {
                waitReleased.notifyAll()
            }
        }
    }

    /**
     * Waits, as handle `waiter` that gave way on a loop, until the query it waited for is let go of:
     * by then its owner has computed the loop on its own handle, and left what it found.
     *
     * @throws CancelledException - if `unwindIfCancelled` does, looked at every `CLAIM_WAIT`
     */
    func giveWay(waiter: Int64, unwindIfCancelled: () -> Unit): Unit {
        while (true) {
            let waiting = synchronized(waitLock) {
                if (waitsFor.contains(waiter)) {
                    waitReleased.wait(timeout: CLAIM_WAIT)
                }
                waitsFor.contains(waiter)
            }
            if (!waiting) {
                return
            }
            try {
                unwindIfCancelled()
            } catch (e: CancelledException) {
                stopWaiting(waiter)
                throw e
            }
        }
    }

    /**
     * How many handles wait for another's memo: for tests, to know one got there.
     */
    func waiting(): Int64 {
        synchronized(waitLock) {
            waitsFor.size
        }
    }

    /**
     * @throws CancelledException - if a write is pending, or `pinned` is a revision gone by
     */
    @Frozen
    func unwindIfCancelled(pinned: ?Int64): Unit {
        if (isCancelled(pinned)) {
            throw CancelledException()
        }
    }

    /**
     * Whether a write is pending, or `pinned` is a revision gone by.
     */
    @Frozen
    func isCancelled(pinned: ?Int64): Bool {
        if (writePending.load()) {
            return true
        }
        match (pinned) {
            case Some(revision) => revision != this.revision
            case None => false
        }
    }
}
