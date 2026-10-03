package calca

import std.unittest.*
import std.unittest.testmacro.*
import calca.macros.*

@CalcaTracked
func totalLength(db: TestDb, a: SourceFile, b: SourceFile): Int64 {
    db.log("totalLength")
    a.text(db).size + b.text(db).size
}

@CalcaTracked
func batchesAnInput(db: TestDb, file: SourceFile): Int64 {
    match (db as TestDatabase) {
        case Some(writable) => writable.storage.batch {file.setText(writable).to("")}
        case None => ()
    }
    0
}

@Test
class BatchTest {
    @TestCase
    func everyChangeInABatchIsOneRevision(): Unit {
        // arrange
        let db = TestDatabase()
        let a = SourceFile(db, "a.cj", "a")
        let b = SourceFile(db, "b.cj", "b")
        let c = SourceFile(db, "c.cj", "c")
        let before = db.storage.runtime.revision

        // act
        db.storage.batch {
            a.setText(db).to("aa")
            b.setText(db).to("bb")
            c.setText(db).to("cc")
        }

        // assert
        @Expect(db.storage.runtime.revision, before + 1)
        @Expect([a.text(db), b.text(db), c.text(db)], ["aa", "bb", "cc"])
    }

    @TestCase
    func aQueryReadingTwoInputsOfABatchRunsAgainOnce(): Unit {
        // arrange
        let db = TestDatabase()
        let a = SourceFile(db, "a.cj", "a")
        let b = SourceFile(db, "b.cj", "b")
        let snapshot = db.snapshot()
        @Expect(totalLength(snapshot, a, b), 2)
        db.events.take()

        // act
        db.storage.batch {
            a.setText(db).to("aa")
            b.setText(db).to("bbb")
        }

        // assert
        @AssertThrows[CancelledException](totalLength(snapshot, a, b))
        @Expect(totalLength(db, a, b), 5)
        @Expect(db.events.take(), ["totalLength"])
    }

    @TestCase
    func anInputCreatedInABatchIsThereAfterIt(): Unit {
        // arrange
        let db = TestDatabase()
        let a = SourceFile(db, "a.cj", "a")

        // act
        let created = db.storage.batch {
            a.setText(db).to("aa")
            SourceFile(db, "b.cj", "bbb")
        }

        // assert
        @Expect(created.text(db), "bbb")
        @Expect(totalLength(db, a, created), 5)
    }

    @TestCase
    func aBatchReadsNothing(): Unit {
        // arrange
        let db = TestDatabase()
        let a = SourceFile(db, "a.cj", "a")

        // act, assert
        @AssertThrows[IllegalStateException](db.storage.batch {a.text(db)})
        @AssertThrows[IllegalStateException](db.storage.batch {length(db, a)})
    }

    @TestCase
    func neitherASnapshotNorAQueryCanBatch(): Unit {
        // arrange
        let db = TestDatabase()
        let a = SourceFile(db, "a.cj", "a")

        // act, assert
        @AssertThrows[IllegalStateException](db.snapshot().storage.batch {a.setText(db).to("b")})
        @AssertThrows[IllegalStateException](batchesAnInput(db, a))
        @Expect(a.text(db), "a")
    }

    @TestCase
    func aBatchThatThrowsLeavesTheDatabaseUsable(): Unit {
        // arrange
        let db = TestDatabase()
        let a = SourceFile(db, "a.cj", "a")

        // act
        @AssertThrows[IllegalArgumentException](db.storage.batch {
            a.setText(db).to("changed")
            throw IllegalArgumentException("midway")
        })

        // assert - what it changed stays changed, and the next write and read go through
        @Expect(a.text(db), "changed")
        a.setText(db).to("again")
        @Expect(length(db.snapshot(), a), 5)
    }
}
