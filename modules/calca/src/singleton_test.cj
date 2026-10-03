package calca

import std.unittest.*
import std.unittest.testmacro.*
import calca.macros.*

@CalcaInput[singleton]
struct Settings {
    var tabSize: Int64
}

@CalcaTracked
func tabSizeOrDefault(db: TestDb): Int64 {
    db.log("tabSizeOrDefault")
    match (Settings.tryGet(db)) {
        case Some(settings) => settings.tabSize(db)
        case None => 4
    }
}

@Test
class SingletonTest {
    @TestCase
    func aSingletonIsNotThereUntilCreated(): Unit {
        // arrange
        let db = TestDatabase()

        // act, assert
        @Expect(Settings.tryGet(db).isNone())
        let thrown = @AssertThrows[IllegalStateException](Settings.get(db))
        @Expect(thrown.message, "no Settings in this database")
    }

    @TestCase
    func aSingletonCreatedIsFoundByItsType(): Unit {
        // arrange
        let db = TestDatabase()

        // act
        let created = Settings(db, 2)

        // assert
        @Expect(Settings.get(db), created)
        @Expect(Settings.tryGet(db), Some(created))
        @Expect(Settings.get(db).tabSize(db), 2)
    }

    @TestCase
    func aSecondSingletonIsRefused(): Unit {
        // arrange
        let db = TestDatabase()
        Settings(db, 2)

        // act
        let thrown = @AssertThrows[IllegalStateException](Settings(db, 8))

        // assert
        @Expect(thrown.message, "Settings is a singleton, and there is one already")
        @Expect(Settings.get(db).tabSize(db), 2)
    }

    @TestCase
    func aQueryThatFoundNoSingletonRunsAgainOnceItIsCreated(): Unit {
        // arrange
        let db = TestDatabase()
        @Expect(tabSizeOrDefault(db), 4)
        db.events.take()

        // act
        Settings(db, 2)
        let result = tabSizeOrDefault(db)

        // assert
        @Expect(result, 2)
        @Expect(db.events.take(), ["tabSizeOrDefault"])
    }

    @TestCase
    func aQueryReadingASingletonsFieldRunsAgainOnceItIsSet(): Unit {
        // arrange
        let db = TestDatabase()
        let settings = Settings(db, 2)
        @Expect(tabSizeOrDefault(db), 2)
        db.events.take()

        // act
        settings.setTabSize(db).to(8)
        let result = tabSizeOrDefault(db)

        // assert
        @Expect(result, 8)
        @Expect(db.events.take(), ["tabSizeOrDefault"])
    }

    @TestCase
    func aSnapshotSeesTheSingletonCreatedBeforeIt(): Unit {
        // arrange
        let db = TestDatabase()
        let before = db.snapshot()
        Settings(db, 2)

        // act
        let snapshot = db.snapshot()

        // assert
        @Expect(Settings.get(snapshot).tabSize(snapshot), 2)
        @AssertThrows[CancelledException](Settings.tryGet(before))
    }

    @TestCase
    func neitherASnapshotNorAQueryCanCreateASingleton(): Unit {
        // arrange
        let db = TestDatabase()

        // act, assert
        @AssertThrows[IllegalStateException](Settings(db.snapshot(), 2))
        @Expect(Settings.tryGet(db).isNone())
    }
}
