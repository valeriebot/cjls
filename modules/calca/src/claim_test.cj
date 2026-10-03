package calca

import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import calca.macros.*

/**
 * Parks between two reads of the file, so a write pending by then cancels it.
 */
@CalcaTracked
func parkedSize(db: TestDb, file: SourceFile): Int64 {
    db.log("parkedSize(${file})")
    let text = file.text(db)
    db.park()
    file.path(db)
    text.size
}

@CalcaTracked
func needsTheOther(db: TestDb, file: SourceFile): Int64 {
    db.park()
    needsTheFirst(db, file) + 1
}

@CalcaTracked
func needsTheFirst(db: TestDb, file: SourceFile): Int64 {
    db.park()
    needsTheOther(db, file) + 1
}

@CalcaTracked[cycleResult: parkedHeadFallback]
func parkedHead(db: TestDb, file: SourceFile): Int64 {
    db.park()
    parkedTail(db, file) + 1
}

func parkedHeadFallback(_: TestDb, _: SourceFile): Int64 {
    -1
}

@CalcaTracked[cycleResult: parkedTailFallback]
func parkedTail(db: TestDb, file: SourceFile): Int64 {
    db.park()
    parkedHead(db, file) + 1
}

func parkedTailFallback(_: TestDb, _: SourceFile): Int64 {
    -2
}

/**
 * `query` on `db`, spawned: its value, or what it threw.
 */
func spawnQuery(db: TestDatabase, query: (TestDatabase) -> Int64): Future<Result<Int64>> {
    spawn {
        try {
            Result.Ok(query(db))
        } catch (e: Exception) {
            Result.Err(e)
        }
    }
}

enum Result<T> {
    | Ok(T)
    | Err(Exception)

    func isCancelled(): Bool {
        match (this) {
            case Err(e) => e is CancelledException
            case _ => false
        }
    }

    func isCycle(): Bool {
        match (this) {
            case Err(e) => e is CycleException
            case _ => false
        }
    }

    func value(): ?T {
        match (this) {
            case Ok(value) => value
            case _ => None
        }
    }
}

@Test
class ClaimTest {
    @TestCase
    func aSecondHandleWaitsForTheFirstAndDoesNotRunTheBody(): Unit {
        // arrange - the first handle is inside the body
        let db = TestDatabase()
        let file = SourceFile(db, "a.cj", "hello")
        let owner = spawnQuery(db.snapshot()) {s => parkedSize(s, file)}
        db.parking.parked.remove()

        // act
        let waiter = spawnQuery(db.snapshot()) {s => parkedSize(s, file)}
        waitForWaiters(db, 1)
        db.parking.released.add(())

        // assert
        @Expect(owner.get().value(), Some(5))
        @Expect(waiter.get().value(), Some(5))
        @Expect(db.events.take(), ["parkedSize(SourceFile(0))"])
        @Expect(db.storage.runtime.waiting(), 0)
    }

    @TestCase
    func aWriteCancelsTheOwnerAndTheHandleWaitingForIt(): Unit {
        // arrange
        let db = TestDatabase()
        let file = SourceFile(db, "a.cj", "hello")
        let probe = db.snapshot()
        let owner = spawnQuery(db.snapshot()) {s => parkedSize(s, file)}
        db.parking.parked.remove()
        let waiter = spawnQuery(db.snapshot()) {s => parkedSize(s, file)}
        waitForWaiters(db, 1)

        // act
        let write = spawn {
            file.setText(db).to("bye")
        }
        waitUntilCancelled(probe)
        db.parking.released.add(())

        // assert
        @Expect(owner.get().isCancelled())
        @Expect(waiter.get().isCancelled())
        @Expect(write.get(), "hello")
        db.parking.disabled.store(true)
        @Expect(parkedSize(db, file), 3)
    }

    @TestCase
    func aWaiterAskedToStopStopsWaiting(): Unit {
        // arrange
        let db = TestDatabase()
        let file = SourceFile(db, "a.cj", "hello")
        let owner = spawnQuery(db.snapshot()) {s => parkedSize(s, file)}
        db.parking.parked.remove()
        let stop = AtomicBool(false)
        let waiter = spawnQuery(db.snapshot(cancelledBy: {=> stop.load()})) {s => parkedSize(s, file)}
        waitForWaiters(db, 1)

        // act
        stop.store(true)
        let stopped = waiter.get()
        db.parking.released.add(())

        // assert - the owner goes on as if nothing happened
        @Expect(stopped.isCancelled())
        @Expect(owner.get().value(), Some(5))
    }

    @TestCase
    func twoHandlesNeedingEachOthersMemoAreACycleNotADeadlock(): Unit {
        // arrange - each handle claims one memo, and parks before it needs the other's
        let db = TestDatabase()
        let file = SourceFile(db, "a.cj", "hello")
        let first = spawnQuery(db.snapshot()) {s => needsTheOther(s, file)}
        db.parking.parked.remove()
        let second = spawnQuery(db.snapshot()) {s => needsTheFirst(s, file)}
        db.parking.parked.remove()

        // act
        db.parking.disabled.store(true)
        db.parking.released.add(())
        db.parking.released.add(())

        // assert
        @Expect(first.get().isCycle())
        @Expect(second.get().isCycle())
        @Expect(db.storage.runtime.waiting(), 0)
    }

    @TestCase
    func aCycleAcrossHandlesWithFallbacksGivesEachHandleItsFallback(): Unit {
        // arrange - each handle claims one end of the cycle, and parks before it needs the other
        let db = TestDatabase()
        let file = SourceFile(db, "a.cj", "hello")
        let fromHead = spawnQuery(db.snapshot()) {s => parkedHead(s, file)}
        db.parking.parked.remove()
        let fromTail = spawnQuery(db.snapshot()) {s => parkedTail(s, file)}
        db.parking.parked.remove()

        // act
        db.parking.disabled.store(true)
        db.parking.released.add(())
        db.parking.released.add(())

        // assert - as on one handle, whichever handle closed the loop
        @Expect(fromHead.get().value(), Some(-1))
        @Expect(fromTail.get().value(), Some(-2))
        @Expect(db.storage.runtime.waiting(), 0)
    }

    @TestCase
    func aHandleGivingWayOnALoopStopsWhenAskedTo(): Unit {
        // arrange - each handle parks on its own: the first waits for the second, which closes the
        // loop and gives way to it; the first takes over the cycle, and parks in it
        let db = TestDatabase()
        let file = SourceFile(db, "a.cj", "hello")
        let headParking = Parking()
        let tailParking = Parking()
        let fromHead = spawnQuery(db.snapshot(parking: headParking)) {s => parkedHead(s, file)}
        headParking.parked.remove()
        let stop = AtomicBool(false)
        let fromTail = spawnQuery(db.snapshot(cancelledBy: {=> stop.load()}, parking: tailParking)) {
            s => parkedTail(s, file)
        }
        tailParking.parked.remove()
        headParking.released.add(())
        waitForWaiters(db, 1)
        tailParking.released.add(())
        headParking.parked.remove()

        // act
        stop.store(true)
        let stopped = fromTail.get()
        headParking.disabled.store(true)
        headParking.released.add(())

        // assert
        @Expect(stopped.isCancelled())
        @Expect(fromHead.get().value(), Some(-1))
        @Expect(db.storage.runtime.waiting(), 0)
    }

    /**
     * Spins until `count` handles wait for another's memo.
     */
    private func waitForWaiters(db: TestDatabase, count: Int64): Unit {
        while (db.storage.runtime.waiting() < count) {}
    }

    /**
     * Spins until the write spawned has cancelled what is in flight: `probe` is a snapshot of the
     * revision before it.
     */
    private func waitUntilCancelled(probe: TestDatabase): Unit {
        while (true) {
            try {
                probe.unwindIfCancelled()
            } catch (_: CancelledException) {
                return
            }
        }
    }
}
