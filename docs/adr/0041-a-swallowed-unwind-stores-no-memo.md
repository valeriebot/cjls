# ADR-0041: A query that swallows calca's unwinding stores no memo, and throws it again

Status: accepted, 2026-10-04

## Context

- calca unwinds a query with exceptions: `CancelledException` (D8), `CycleUnwindException` to a fallback, `VerifyingCycleException` to whoever verifies a key needed again, `GiveWayException` to the query a loop of handles waits for (D35). All are `Exception`s.
- A body with `catch (e: Exception)` around a fetch, natural in a resolver tolerating broken code, catches them too, and returns: its memo misses the read that threw, and is current in a revision maybe cancelled (#100).
- What `catch (e: Exception)` does not catch, a user class cannot be: `Throwable` is not public in `std.core`, and `Error`'s constructors are not open to a subclass (cjc `1.3.0-alpha.20261002001050`).

## Decision

- **The unwinding marks every query it unwinds** (`ActiveQuery.unwoundBy`, `Storage.unwinding`): all of the handle's for a cancellation, those above the key it unwinds to for the others. A query begun after it is not marked.
- **A marked query whose body returns stores nothing, and throws the same exception again** (`MemoTable.execute`): the unwinding goes on to whoever it was for, as if the body had not caught it.
- `CycleUnwindException` needs no mark: a query on a recovered cycle takes its fallback whatever its body returns.

## Consequences

- A body catching `Exception` around a fetch is no longer wrong, only useless: what it returns on calca's exceptions is dropped. The rule stays to catch narrower (A21).
- Work a swallowing body does after the catch is wasted until it returns; a cancelled one stops at its next calca call anyway.
- Marking costs a walk of the handle's stack per exception thrown, nothing on the way that does not throw.
