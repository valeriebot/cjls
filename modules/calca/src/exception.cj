package calca

/**
 * Thrown out of a query whose answer nobody needs any more: a write is waiting for it to end, or
 * its snapshot is of a revision gone by, and nothing it computes would be current; or whoever uses
 * the snapshot asked it to stop. Catch it where the handle is used, and drop the handle.
 */
public class CancelledException <: Exception {
    CancelledException() {
        super("the query was cancelled")
    }

    protected func getClassName(): String {
        "CancelledException"
    }
}

/**
 * Thrown when a tracked function ends up needing its own result, directly or through others, and
 * not every query on the cycle has a fallback (`@CalcaTracked[cycleResult: f]`).
 */
public class CycleException <: Exception {
    /**
     * The queries on the cycle, described as `name(id)`, from the one needed again on.
     */
    public let participants: Array<String>

    CycleException(message: String, participants: Array<String>) {
        super(message)
        this.participants = participants
    }

    protected func getClassName(): String {
        "CycleException"
    }
}

/**
 * Unwinds a query on a cycle whose queries all have a fallback, to where it takes its own.
 */
class CycleUnwindException <: Exception {
    CycleUnwindException() {
        super("a query on a cycle unwinds to its fallback")
    }

    protected func getClassName(): String {
        "CycleUnwindException"
    }
}

/**
 * Unwinds a handle that would close a loop of handles waiting for one another to `key`, the query of
 * its own the loop waits for: whoever claimed it lets go of it, and waits for the handle it gave way
 * to, which computes the loop on its own handle, then fetches it again.
 */
class GiveWayException <: Exception {
    GiveWayException(let key: DatabaseKey) {
        super("a handle closing a loop of waits gives way")
    }

    protected func getClassName(): String {
        "GiveWayException"
    }
}

/**
 * Unwinds to whoever verifies `key`, which a query executing meanwhile needed: a cycle, found by
 * executing the key rather than verifying it.
 */
class VerifyingCycleException <: Exception {
    VerifyingCycleException(let key: DatabaseKey) {
        super("a query being verified is needed again")
    }

    protected func getClassName(): String {
        "VerifyingCycleException"
    }
}
