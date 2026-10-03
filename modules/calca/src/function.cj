package calca

import std.collection.*
import std.collection.concurrent.*
import std.sync.*

/**
 * How long a handle waiting for another's memo goes before it looks whether it was asked to stop.
 */
let CLAIM_WAIT = Duration.millisecond * 10

/**
 * A `@CalcaTracked` function, process-wide: where its memos are in any database. Held by the static
 * `@CalcaTracked` generates; not for use by hand.
 *
 * The body comes with every `fetch`, as the type `B` it is a static function of, rather than here:
 * a static whose initializer reaches the body does not compile once tracked functions call each
 * other, since cjc then sees the static used before it is initialized. A type, not a closure: a
 * closure would be allocated by every call.
 *
 * `equal` tells whether a value computed again is the one remembered, in which case the memo keeps
 * the revision it last changed in and what read it need not run again ("backdating").
 *
 * `lru` keeps the values of only that many keys, the ones last fetched, from one revision to the
 * next; the others lose their value but keep what they read, and are computed again when fetched.
 * `None` keeps every value.
 */
public class TrackedFunction<D, K, V> where D <: Database, K <: Hashable & Equatable<K> {
    let index: Int64

    public TrackedFunction(let name: String, let equal: (V, V) -> Bool, let lru!: ?Int64 = None) {
        index = reserveIngredients(1)
    }

    /**
     * The value of the function at `key`: remembered, if nothing it read has changed since, else
     * computed again. Recorded as read by the query running.
     *
     * @throws CancelledException - if a write is pending, or `db` is a snapshot of a revision gone
     * by
     * @throws CycleException - if the value is already being computed on this handle
     */
    @Frozen
    public func fetch<B>(db: D, key: K): V where B <: TrackedBody<D, K, V> {
        let storage = db.storage
        let outermost = storage.beginOperation()
        try {
            let memos = storage.runtime.existing<MemoTable<D, K, V>>(index) ?? storage.runtime.ingredient(index) {
                => memoTable<B>()
            }
            let (value, memo, id) = memos.fetchValue(db, storage, key)
            storage.reportRead(DatabaseKey(index, id), memo.durability, memo.changedAt)
            value
        } finally {
            storage.endOperation(outermost)
        }
    }

    private func memoTable<B>(): MemoTable<D, K, V> where B <: TrackedBody<D, K, V> {
        let recover: ?(D, K) -> V = if (B.calcaHasFallback()) {
            {db: D, key: K => B.calcaFallback(db, key)}
        } else {
            None
        }
        MemoTable(this, {db: D, key: K => B.calcaExecute(db, key)}, recover)
    }
}

/**
 * The body of a `@CalcaTracked` function, and its fallback on a cycle if it has one: what the type
 * `@CalcaTracked` generates beside the function implements, for `TrackedFunction.fetch` to call.
 */
public interface TrackedBody<D, K, V> {
    static func calcaExecute(db: D, key: K): V

    /**
     * Whether it has a fallback, `@CalcaTracked[cycleResult: …]`.
     */
    static func calcaHasFallback(): Bool {
        false
    }

    static func calcaFallback(_: D, _: K): V {
        throw IllegalStateException("no fallback")
    }
}

/**
 * What the keys of a memo table are or hold of interned values, and for each such value the memos
 * it keys: one when the keys are the values themselves, any number when they hold them among other
 * fields.
 */
enum KeysOfInterned {
    | KeysUnknown
    | KeysOfNone
    | KeysAreInterned(HashMap<DatabaseKey, Id>)
    | KeysHoldInterned(HashMap<DatabaseKey, HashSet<Id>>)
}

/**
 * A value computed, with what it was computed from. An evicted memo has lost its value, but still
 * knows what it read and when it last changed, so it can be verified without computing it again.
 */
class Memo<V> {
    /**
     * The last revision this value is known to be current in.
     */
    let verifiedAt: AtomicInt64

    Memo(
        verifiedAt: Int64,
        let value: ?V,
        let changedAt: Int64,
        let durability: Durability,
        let dependencies: Array<DatabaseKey>
    ) {
        this.verifiedAt = AtomicInt64(verifiedAt)
    }

    /**
     * This memo without its value.
     */
    func evicted(): Memo<V> {
        Memo<V>(verifiedAt.load(), None, changedAt, durability, dependencies)
    }
}

/**
 * The key of a memo table, its `Id`, and the memo at it, `None` until it is first computed. The memo
 * is replaced under the table's lock and read without it.
 */
class MemoEntry<K, V> {
    let memo = AtomicOptionReference<Memo<V>>()

    /**
     * Its slot, given as it goes into the table, before any other handle can find it.
     */
    var id = Id(0)

    MemoEntry(let key: K) {}
}

/**
 * The memos of one tracked function in one database, one per key it was called with. A key's `Id`
 * is its slot in a `Slab`, given the first time it is seen, so what depends on it can name it.
 *
 * Keyed by an `@CalcaInterned` type, or by several values any of which is of one, the table drops a
 * memo once a value its key is or holds is collected, and its slot is reused under the next
 * generation: a memo that read the dropped one finds its `Id` stale, and counts it as changed.
 *
 * One handle at a time verifies or computes a memo: it claims the key, and another handle needing
 * it waits for the claim to go, then takes what the owner left, verified or computed. A memo already
 * verified in the current revision is read without a claim, and without the lock (C9): the entries
 * are found by key in a `ConcurrentHashMap`, and the lock goes only around what changes them.
 */
class MemoTable<D, K, V> <: Ingredient & KeyedByInterned where D <: Database, K <: Hashable & Equatable<K> {
    private let lock = Mutex()
    let entries = Slab<MemoEntry<K, V>>()
    private let byKey = ConcurrentHashMap<K, MemoEntry<K, V>>()

    /**
     * The handle verifying or computing the memo at each key claimed.
     */
    private let claims = HashMap<Id, Int64>()

    /**
     * Notified as a claim goes.
     */
    private let released: Condition

    /**
     * Which interned values the keys are or hold, and which memos each of them keys; unknown until
     * the first key.
     */
    private var interned: KeysOfInterned = KeysUnknown

    /**
     * The interned tables this one is registered with, by ingredient.
     */
    private let watched = HashSet<Int64>()

    /**
     * When the function keeps only some values, the keys whose memo may hold one, in the order they
     * were last fetched. Touched and trimmed under `lock`, together: a value goes as soon as more
     * than `lru` keys were fetched after it, within a revision too.
     */
    private let used: ?IdLru

    /**
     * The function itself, the same whichever `fetch` gave it.
     */
    MemoTable(let function: TrackedFunction<D, K, V>, let body: (D, K) -> V, let recover: ?(D, K) -> V) {
        used = function.lru.map {capacity => IdLru(capacity)}
        lock.lock()
        released = lock.condition()
        lock.unlock()
    }

    /**
     * The entry of `key`, a new one the first time it is seen. Called with the lock held.
     */
    @Frozen
    private func internLocked(runtime: Runtime, key: K): MemoEntry<K, V> {
        if (let Some(entry) <- byKey.get(key)) {
            return entry
        }
        let entry = MemoEntry<K, V>(key)
        entry.id = entries.insert(entry)
        byKey.add(key, entry)
        match (keysOfInterned(key)) {
            case KeysAreInterned(memos) =>
                let value = (key as InternedValue).getOrThrow().calcaKey()
                watch(runtime, value.ingredient)
                memos.add(value, entry.id)
            case KeysHoldInterned(memos) =>
                for (value in internedFields(key)) {
                    watch(runtime, value.ingredient)
                    match (memos.get(value)) {
                        case Some(ids) => ids.add(entry.id)
                        case None => memos.add(value, HashSet<Id>([entry.id]))
                    }
                }
            case _ => ()
        }
        entry
    }

    /**
     * Which interned values the keys are or hold. The first key decides: a macro sees only tokens,
     * so which type a key is is found out here. Called with the lock held.
     */
    @Frozen
    private func keysOfInterned(key: K): KeysOfInterned {
        if (let KeysUnknown <- interned) {
            interned = if ((key as InternedValue).isSome()) {
                KeysAreInterned(HashMap<DatabaseKey, Id>())
            } else if ((key as InternedFields).isSome()) {
                KeysHoldInterned(HashMap<DatabaseKey, HashSet<Id>>())
            } else {
                KeysOfNone
            }
        }
        interned
    }

    /**
     * The interned values among the fields of `key`, a key of several values.
     */
    private func internedFields(key: K): ArrayList<DatabaseKey> {
        let values = ArrayList<DatabaseKey>()
        for (field in (key as InternedFields).getOrThrow().calcaInterned()) {
            if (let Some(value) <- field) {
                values.add(value)
            }
        }
        values
    }

    /**
     * Registers the table with the interned one at `ingredient`, to be told what it collects, unless
     * it is already. Called with the lock held.
     */
    private func watch(runtime: Runtime, ingredient: Int64): Unit {
        if (watched.contains(ingredient)) {
            return
        }
        let table = (runtime.ingredientAt(ingredient) as InternedKeys).getOrThrow {
            => IllegalStateException("${function.name} is keyed by ${ingredient}, which interns nothing")
        }
        table.watch(this)
        watched.add(ingredient)
    }

    /**
     * Drops the memos keyed by the values `collected` of the interned type at `ingredient`, and by
     * keys holding any of them; their keys' `Id`s go with them.
     */
    public func dropKeys(ingredient: Int64, collected: Array<Id>): Unit {
        synchronized(lock) {
            match (interned) {
                case KeysAreInterned(memos) => for (value in collected) {
                    drop(memos.remove(DatabaseKey(ingredient, value)) ?? continue)
                }
                case KeysHoldInterned(memos) => for (value in collected) {
                    let gone = DatabaseKey(ingredient, value)
                    for (id in memos.remove(gone) ?? continue) {
                        let entry = drop(id) ?? continue
                        // the other values its key held no longer key it
                        for (other in internedFields(entry.key) where other != gone) {
                            if (let Some(ids) <- memos.get(other)) {
                                ids.remove(id)
                                if (ids.isEmpty()) {
                                    memos.remove(other)
                                }
                            }
                        }
                    }
                }
                case _ => ()
            }
        }
    }

    /**
     * Drops the memo at `id`, and gives its entry. Called with the lock held.
     */
    private func drop(id: Id): ?MemoEntry<K, V> {
        used?.remove(Id(id.index))
        let entry = entries.remove(id) ?? return None
        byKey.remove(entry.key)
        entry
    }

    /**
     * The value at `id` and the memo holding it: remembered if the memo is verified, else computed
     * again. A use of the key, as far as `lru` goes; its `Id`, a new one the first time.
     *
     * A hit takes no lock, unless the function keeps only some values and the use has to be
     * recorded, and marks nothing as being worked on: a memo verified in this revision is neither
     * verified nor computed on any handle.
     */
    @Frozen
    func fetchValue(db: D, storage: Storage, key: K): (V, Memo<V>, Id) {
        if (used.isNone()) {
            if (let Some(entry) <- byKey.get(key)) {
                if (let Some(hit) <- current(entry, storage.runtime)) {
                    return hit
                }
            }
        }
        let entry = synchronized(lock) {
            let entry = internLocked(storage.runtime, key)
            touchLocked(entry.id)
            entry
        }
        if (let Some(hit) <- current(entry, storage.runtime)) {
            return hit
        }
        let (value, memo) = fetchCold(db, storage, entry.id, key)
        (value, memo, entry.id)
    }

    /**
     * The value at `entry`, if its memo has one and is verified in this revision.
     */
    @Frozen
    private func current(entry: MemoEntry<K, V>, runtime: Runtime): ?(V, Memo<V>, Id) {
        let memo = entry.memo.load() ?? return None
        let value = memo.value ?? return None
        if (memo.verifiedAt.load() != runtime.revision) {
            return None
        }
        (value, memo, entry.id)
    }

    /**
     * `fetchValue` of a memo not verified in this revision, or without a value. Fetched again once
     * the handle gave way on a loop of waits whose query of its own is this one.
     */
    private func fetchCold(db: D, storage: Storage, id: Id, key: K): (V, Memo<V>) {
        let databaseKey = DatabaseKey(function.index, id)
        while (true) {
            try {
                return fetchClaimed(db, storage, databaseKey, key)
            } catch (e: GiveWayException) {
                if (e.key != databaseKey) {
                    throw e
                }
                storage.giveWay()
            }
        }
        throw IllegalStateException("unreachable")
    }

    private func fetchClaimed(db: D, storage: Storage, databaseKey: DatabaseKey, key: K): (V, Memo<V>) {
        storage.enter(databaseKey)
        try {
            let old = synchronized(lock) {
                claim(storage, databaseKey)
                // the owner waited for may have left it verified or computed
                entry(databaseKey.id).memo.load()
            }
            try {
                match (old) {
                    case Some(memo) => match (memo.value) {
                        case Some(value) where verify(db, storage.runtime, memo, databaseKey) => (value, memo)
                        case None where verify(db, storage.runtime, memo, databaseKey) =>
                            execute(db, storage, databaseKey, key, old, unchanged: true)
                        case _ => execute(db, storage, databaseKey, key, old, unchanged: false)
                    }
                    case None => execute(db, storage, databaseKey, key, old, unchanged: false)
                }
            } finally {
                release(storage, databaseKey)
            }
        } finally {
            storage.exit(databaseKey)
        }
    }

    /**
     * Makes `storage` the one handle verifying or computing the memo at `key`, once whoever does
     * now is done. Called with the lock held, which a wait lets go of.
     *
     * @throws GiveWayException - if the handle computing it waits, through others or not, for this
     * one, which is to give way: it still waits for the key, until its owner lets go of it
     * @throws CancelledException - if a write is pending, or the waiting handle was asked to stop
     */
    private func claim(storage: Storage, key: DatabaseKey): Unit {
        var waited = false
        while (let Some(owner) <- claims.get(key.id)) {
            try {
                storage.runtime.startWaiting(storage.handle, owner, key)
            } catch (e: GiveWayException) {
                throw storage.givingWay(e)
            }
            waited = true
            try {
                // no one tells a waiter its own snapshot was asked to stop: it looks now and then
                released.wait(timeout: CLAIM_WAIT)
                storage.unwindIfCancelled()
            } catch (e: CancelledException) {
                storage.runtime.stopWaiting(storage.handle)
                throw e
            }
        }
        if (waited) {
            storage.runtime.stopWaiting(storage.handle)
        }
        claims.add(key.id, storage.handle)
    }

    private func release(storage: Storage, key: DatabaseKey): Unit {
        synchronized(lock) {
            claims.remove(key.id)
            storage.runtime.released(key)
            released.notifyAll()
        }
    }

    /**
     * Whether `memo` is current, marking it so if it is. Cheap when no input it could have read
     * changed since it was last verified; otherwise asks each of its dependencies in turn, which
     * may verify or execute those. A memo needed again while its dependencies are asked is not
     * current: executing it finds the cycle, and recovers from it if it can.
     */
    private func verify(db: D, runtime: Runtime, memo: Memo<V>, key: DatabaseKey): Bool {
        let now = runtime.revision
        let verifiedAt = memo.verifiedAt.load()
        if (verifiedAt == now) {
            return true
        }
        let changed = try {
            runtime.lastChangedAt(memo.durability) > verifiedAt && memo.dependencies.iterator().any {
                dependency => runtime.ingredientAt(dependency.ingredient).maybeChangedAfter(db, dependency.id, verifiedAt)
            }
        } catch (e: VerifyingCycleException) {
            if (e.key != key) {
                throw e
            }
            true
        }
        if (changed) {
            return false
        }
        memo.verifiedAt.store(now)
        true
    }

    /**
     * Runs the body and remembers the value. The memo keeps the revision `old` last changed in when
     * the value is the one `old` held, or when `old` was evicted but is `unchanged`: verified, so
     * computed again from what it was computed from before.
     *
     * On a cycle whose queries all have a fallback, the value is the fallback, and the memo depends
     * on what the whole cycle read.
     *
     * A body that catches what unwinds it (`catch (e: Exception)` around a fetch) and returns has
     * computed a value from reads its memo does not know of, maybe in a revision cancelled: what
     * unwinds it is thrown again, and nothing is stored.
     */
    private func execute(db: D, storage: Storage, databaseKey: DatabaseKey, key: K, old: ?Memo<V>,
        unchanged!: Bool): (V, Memo<V>) {
        let frame = storage.push(databaseKey)
        let value = try {
            let computed = body(db, key)
            if (frame.inCycle) {
                fallback(db, key, frame)
            } else {
                computed
            }
        } catch (e: CycleUnwindException) {
            if (!frame.inCycle) {
                throw e
            }
            fallback(db, key, frame)
        } finally {
            storage.pop()
        }
        if (let Some(e) <- frame.unwoundBy) {
            throw e
        }
        let changedAt = match (old) {
            case Some(memo) where frame.durability >= memo.durability && (unchanged || isEqual(memo.value, value)) =>
                memo.changedAt
            case _ => frame.changedAt
        }
        let memo = Memo(storage.runtime.revision, value, changedAt, frame.durability, frame.dependencies.toArray())
        synchronized(lock) {
            entry(databaseKey.id).memo.store(memo)
            touchLocked(databaseKey.id)
        }
        (value, memo)
    }

    /**
     * The fallback of a query on a cycle; what it reads is recorded, and unwinds nothing.
     */
    private func fallback(db: D, key: K, frame: ActiveQuery): V {
        frame.unwinding = false
        let recovered = recover.getOrThrow {=> IllegalStateException("${function.name} has no fallback")}
        recovered(db, key)
    }

    public func hasFallback(): Bool {
        recover.isSome()
    }

    private func isEqual(old: ?V, new: V): Bool {
        match (old) {
            case Some(value) => (function.equal)(value, new)
            case None => false
        }
    }

    /**
     * Verifying the memo at `id` for another one's sake, which is not a use of it. A memo with a
     * value that is not current is computed again, so backdating can tell whether it changed. An
     * evicted one never is: if nothing it read changed, neither did it; else it may have, and
     * whoever fetches it computes it. A memo dropped with its key is changed.
     */
    public func maybeChangedAfter(db: Database, id: Id, revision: Int64): Bool {
        let typed = (db as D).getOrThrow {=> IllegalStateException("${function.name} is given a database of another type")}
        let storage = db.storage
        let databaseKey = DatabaseKey(function.index, id)
        while (true) {
            try {
                return verifyClaimed(typed, storage, databaseKey, revision)
            } catch (e: GiveWayException) {
                if (e.key != databaseKey) {
                    throw e
                }
                storage.giveWay()
            }
        }
        throw IllegalStateException("unreachable")
    }

    private func verifyClaimed(db: D, storage: Storage, databaseKey: DatabaseKey, revision: Int64): Bool {
        storage.enter(databaseKey)
        try {
            let now = storage.runtime.revision
            let found: ?(K, ?Memo<V>, Bool) = synchronized(lock) {
                match (entries.get(databaseKey.id)) {
                    case Some(entry) => match (entry.memo.load()) {
                        case Some(memo) where memo.verifiedAt.load() == now => Some((entry.key, Some(memo), false))
                        case _ =>
                            claim(storage, databaseKey)
                            // the owner waited for may have left it verified or computed
                            Some((entry.key, entry.memo.load(), true))
                    }
                    case None => None
                }
            }
            let (key, old, claimed) = found ?? return true
            try {
                match (old) {
                    case Some(memo) where memo.value.isNone() => !verify(db, storage.runtime, memo, databaseKey) ||
                        memo.changedAt > revision
                    case Some(memo) where verify(db, storage.runtime, memo, databaseKey) => memo.changedAt > revision
                    case _ => execute(db, storage, databaseKey, key, old, unchanged: false)[1].changedAt > revision
                }
            } finally {
                if (claimed) {
                    release(storage, databaseKey)
                }
            }
        } finally {
            storage.exit(databaseKey)
        }
    }

    /**
     * Makes `id` the key fetched last, and evicts the values of those fetched least recently, beyond
     * `lru`. A reader holding a value evicted keeps it; the memo, fetched again, is verified by its
     * edges and computed again, keeping its `changedAt` when nothing it read changed.
     */
    private func touchLocked(id: Id): Unit {
        if (let Some(used) <- used) {
            used.touch(id)
            // a hit adds no key: no closure for it
            if (used.size > used.capacity) {
                used.trim(evictLocked)
            }
        }
    }

    private func evictLocked(id: Id): Unit {
        if (let Some((_, entry)) <- entries.getAt(id.index)) {
            entry.memo.store(entry.memo.load()?.evicted())
        }
    }

    /**
     * Evicts what a fetch that did not end left beyond `lru` (cancelled, or unwound by a cycle).
     */
    public func newRevision(): Unit {
        synchronized(lock) {
            used?.trim(evictLocked)
        }
    }

    public func describe(id: Id): String {
        "${function.name}(${id})"
    }

    /**
     * Called with the lock held.
     */
    @Frozen
    private func entry(id: Id): MemoEntry<K, V> {
        entries.get(id).getOrThrow {=> IllegalStateException("${function.name} has no key ${id}")}
    }
}
