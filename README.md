# pg_promise_guard

Finds the guarantees your schema **claims** to give and silently stopped giving.

```sql
CREATE EXTENSION pg_promise_guard;

SELECT * FROM promise_breaks;
```
```
         kind         |       object        |   relation   | severity
----------------------+---------------------+--------------+----------
 invalid_unique_index | app.clientes_rut_uk | app.clientes | breach
 disabled_trigger     | app.audita          | app.facturas | breach
 unenforced_rls       | app.tenant_data     | app.tenant_data | breach
 not_valid_constraint | app.monto_positivo  | app.facturas | gap
```

## The failure it exists for

A migration runs `CREATE UNIQUE INDEX CONCURRENTLY`. It fails on duplicates that
were already in the table — and it **leaves the index behind**, marked unique,
marked invalid. From that moment `\d` says `UNIQUE`, your ORM says unique, your
application logic assumes unique, and **nothing is enforced**. Duplicates keep
going in. No error, no log line, no alert.

The failure was loud exactly once, in a deploy log nobody reads twice. The broken
state it leaves behind is silent forever. That asymmetry is the whole point: a
loud, one-off event is precisely what needs a periodic sentinel rather than one
more alert.

Same shape, different clothes:

| what the schema says | what is actually happening |
|---|---|
| `UNIQUE` index | invalid — duplicates go in |
| `CHECK` / `FOREIGN KEY` constraint | `NOT VALID` — the rows already there were never checked |
| audit trigger | `DISABLED` for a bulk load, never re-enabled |
| row level security | `ENABLED` but not `FORCED` — the table owner bypasses every policy |

## Why not amcheck

`amcheck` verifies that a **valid** index is structurally sound. These indexes
are structurally perfect and simply **not in effect**. Different question,
different answer — running amcheck on an invalid index tells you nothing about
the uniqueness you think you have.

## breach vs gap

- **breach** — the schema states a guarantee that is *not being enforced right
  now*. Wrong data can be entering as you read this.
- **gap** — the guarantee holds from here on but does not cover what was already
  there. A `NOT VALID` constraint mid-migration is a legitimate, deliberate
  state.

`promises_kept()` only goes false on a **breach**. A monitor that goes red for a
deliberate intermediate state gets silenced — and takes the real breaches with
it.

```sql
SELECT promises_kept();            -- whole database
SELECT promises_kept('app');       -- one schema
SELECT * FROM check_promises('app');
```

## Cost

Reads the system catalogs only. No user data, no locks, no dependencies, no
shared library — it is one SQL function. Safe to run on a busy production
database and cheap enough to run every minute.

## What it does NOT do

Declared here rather than hidden in the version number:

- It reports **state**, not history. It cannot tell you *when* the index went
  invalid or *who* disabled the trigger.
- It does not check whether a valid index is corrupt — that is `amcheck`.
- It does not look at permissions, `search_path` shadowing, or default
  privileges, all of which can also break assumptions people call "guarantees".
- Objects that belong to an extension are skipped: an extension's own design
  decisions are not your database's mistakes. If you want to audit those too,
  query the catalogs directly.
- Tested on PostgreSQL **18.6 and 19beta2**, both green against the same
  expected output — so nothing here depends on 19. The catalog columns it reads
  (`pg_index.indisvalid`, `pg_constraint.convalidated`, `pg_trigger.tgenabled`,
  `pg_class.relforcerowsecurity`) have existed since 9.5 or earlier, which is
  why `META.json` claims 13, but versions below 18 are **untested** and that is
  stated here rather than implied by the version number.

## Tested on

Measured on 2026-09-16, not assumed: `make installcheck` was run against each
of these releases, every one in a container of the official image for that
version (19beta2 is a local build).

| 10 | 11 | 12 | 13 | 14 | 15 | 16 | 17 | 18 | 19 |
|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| ✗  | ✓  | ✓  | ✓  | ✓  | ✓  | ✓  | ✓  | ✓  | ✓  |

PostgreSQL 10 is out because pg_living_assertions, which this extension needs,
requires 11.

## Tests

```sh
make install
make installcheck
```

The suite does not check that the extension reads the catalog — it **breaks
each promise for real** and then asserts both that the guarantee is genuinely
gone (the duplicate goes in; the audit row is missing) and that the extension
says so. It also asserts that a healthy schema reports **nothing**: a checker
that always finds something gets ignored, and then it is not a checker.

## 0.2.0 -- the scan gets a memory

Everything above answers *what is broken right now*. Run it, get a list; run it
tomorrow, get another list, with no way to tell whether anything changed, when it
was last looked at, or whether anyone has **ever** looked.

That last one matters most: in a scanner with no state, "this schema is clean"
and "nobody has scanned this schema" produce the same empty result -- and an
empty result reads as a clean bill of health.

```sql
SELECT promise_guard.watch('public');       -- register the scan
SELECT * FROM living_assertions.status;      -- verdict AND how old it is
```

This extension still keeps **no state of its own** -- reading the catalog is its
job, remembering that you read it is not. That belongs to
[`pg_living_assertions`](https://pgxn.org/dist/pg_living_assertions/), which
0.2.0 requires. Only `breach` decides the verdict, for the same reason
`promises_kept()` ignores gaps: a check that is red on purpose gets silenced,
and takes the real ones with it.

### A latent defect fixed in 0.2.0

`check_promises()` and `promises_kept()` did not set their own `search_path`, so
they resolved through the **caller's** -- meaning they only worked from a session
that already had the schema in scope. A cron job, a monitoring role or a
`SECURITY DEFINER` context got `function check_promises(text) does not exist`,
and an unqualified name can also resolve to something a user planted earlier in
their path. Every test missed it because every test called them from a session
that had the schema in scope; it surfaced the first time the function ran under
somebody else's `search_path`.

## License

PostgreSQL License.
