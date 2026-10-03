package calca

import std.sync.*
import std.unittest.*
import std.unittest.testmacro.*
import calca.macros.*

/**
 * Tolerates whatever `parkedSize` throws, as a resolver tolerating broken code might.
 */
@CalcaTracked
func tolerantSize(db: TestDb, file: SourceFile): Int64 {
    db.log("tolerantSize")
    try {
        parkedSize(db, file)
    } catch (_: Exception) {
        -100
    }
}

@CalcaTracked[cycleResult: tolerantHeadFallback]
func tolerantHead(db: TestDb, mode: Mode): Int64 {
    if (mode.cyclic(db)) {
        try {
            tolerantTail(db, mode) + 1
        } catch (_: Exception) {
            -100
        }
    } else {
        10
    }
}

func tolerantHeadFallback(_: TestDb, _: Mode): Int64 {
    -1
}

@CalcaTracked[cycleResult: tolerantTailFallback]
func tolerantTail(db: TestDb, mode: Mode): Int64 {
    tolerantHead(db, mode) + 1
}

func tolerantTailFallback(_: TestDb, _: Mode): Int64 {
    -2
}

@CalcaTracked[cycleResult: tolerantParkedHeadFallback]
func tolerantParkedHead(db: TestDb, file: SourceFile): Int64 {
    db.park()
    try {
        tolerantParkedTail(db, file) + 1
    } catch (_: Exception) {
        -100
    }
}

func tolerantParkedHeadFallback(_: TestDb, _: SourceFile): Int64 {
    -1
}

@CalcaTracked[cycleResult: tolerantParkedTailFallback]
func tolerantParkedTail(db: TestDb, file: SourceFile): Int64 {
    db.park()
    try {
        tolerantParkedHead(db, file) + 1
    } catch (_: Exception) {
        -100
    }
}

func tolerantParkedTailFallback(_: TestDb, _: SourceFile): Int64 {
    -2
}

/**
 * A body that catches `Exception` around a fetch catches what calca unwinds its queries with too:
 * what it returns then is not kept, and the unwinding goes on.
 */
@Test
class SwallowTest {
    @TestCase
    func aQueryCatchingTheCancellationOfAWriteStoresNoMemo(): Unit {
        // arrange - the query parks inside the fetch it guards
        let db = TestDatabase()
        let file = SourceFile(db, "a.cj", "hello")
        let probe = db.snapshot()
        let reader = spawnQuery(db.snapshot()) {s => tolerantSize(s, file)}
        db.parking.parked.remove()

        // act
        let write = spawn {
            file.setText(db).to("bye")
        }
        waitUntilCancelled(probe)
        db.parking.released.add(())

        // assert - kept, its value would be current in every revision: it read nothing
        @Expect(reader.get().isCancelled())
        @Expect(write.get(), "hello")
        db.parking.disabled.store(true)
        @Expect(tolerantSize(db, file), 3)
    }

    @TestCase
    func aQueryCatchingTheCancellationItWasAskedForStoresNoMemo(): Unit {
        // arrange
        let db = TestDatabase()
        let file = SourceFile(db, "a.cj", "hello")
        let stop = AtomicBool(false)
        let reader = spawnQuery(db.snapshot(cancelledBy: {=> stop.load()})) {s => tolerantSize(s, file)}
        db.parking.parked.remove()
        db.events.take()

        // act
        stop.store(true)
        db.parking.released.add(())

        // assert - computed again, in the revision it was cancelled in
        @Expect(reader.get().isCancelled())
        db.parking.disabled.store(true)
        @Expect(tolerantSize(db.snapshot(), file), 5)
        @Expect(db.events.take(), ["tolerantSize", "parkedSize(${file})"])
    }

    @TestCase
    func aQueryCatchingTheUnwindOfACycleStillTakesItsFallback(): Unit {
        // arrange
        let db = TestDatabase()
        let mode = Mode(db, true)

        // act
        let fromHead = tolerantHead(db, mode)

        // assert
        @Expect(fromHead, -1)
        @Expect(tolerantTail(db, mode), -2)
    }

    @TestCase
    func aQueryCatchingTheUnwindToAQueryBeingVerifiedStoresNoMemo(): Unit {
        // arrange - no cycle yet: `tolerantTail` reads `tolerantHead`, which reads only the mode
        let db = TestDatabase()
        let mode = Mode(db, false)
        @Expect(tolerantTail(db, mode), 11)

        // act - verifying `tolerantTail` executes `tolerantHead`, which now needs it, and catches the
        // unwind to whoever verifies it
        mode.setCyclic(db).to(true)
        let fromTail = tolerantTail(db, mode)

        // assert - as if it had not caught it
        @Expect(fromTail, -2)
        @Expect(tolerantHead(db, mode), -1)
    }

    @TestCase
    func aQueryCatchingTheUnwindOfAHandleGivingWayStoresNoMemo(): Unit {
        // arrange - each handle claims one end of the cycle, and parks before it needs the other;
        // whichever closes the loop gives way, and its query catches that
        let db = TestDatabase()
        let file = SourceFile(db, "a.cj", "hello")
        let fromHead = spawnQuery(db.snapshot()) {s => tolerantParkedHead(s, file)}
        db.parking.parked.remove()
        let fromTail = spawnQuery(db.snapshot()) {s => tolerantParkedTail(s, file)}
        db.parking.parked.remove()

        // act
        db.parking.disabled.store(true)
        db.parking.released.add(())
        db.parking.released.add(())

        // assert - as if it had not caught it
        @Expect(fromHead.get().value(), Some(-1))
        @Expect(fromTail.get().value(), Some(-2))
        @Expect(db.storage.runtime.waiting(), 0)
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
