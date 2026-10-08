# Changelog

Versions are released on [PGXN](https://pgxn.org/dist/pg_promise_guard/). Each
upgrade script (`pg_promise_guard--OLD--NEW.sql`) documents, in its own header,
exactly what changed and why; that is the authoritative per-version record.

## 0.2.5 -- unreleased

* **An installation that began at 0.1.0 can upgrade, and its `watch()` works.**
  0.1.0 fixed no schema, so it was installed wherever the caller said -- usually
  `public`; 0.2.0 fixed `schema = promise_guard` for new installations only. The
  0.2.3 -> 0.2.4 script named `promise_guard` literally and failed there with
  `schema "promise_guard" does not exist` (found upgrading a real database; the
  failure was all or nothing). The script now says `@extschema@`, as the
  0.1.0 -> 0.2.0 script always did. `watch()` is recreated naming the schema the
  extension is in: the published 0.2.0 already did, and this normalizes a
  `watch()` from a pre-release build that named `promise_guard` literally.
  `test/desde_010.sh` (`make check-desde-010`) reproduces the origin -- 0.1.0
  installed with its own control file, then updated -- which
  `ci/upgrade_check.sh` cannot, since it installs every old version with the
  current control file.

## 0.2.4 -- 2026-10-08

* **A temporary table of the session that evaluates a promise can no longer hide
  a broken one.** `check_promises()` reads the catalog without a schema under
  `search_path = promise_guard, pg_catalog`, and PostgreSQL searches an unnamed
  `pg_temp` first for tables: a temporary `pg_trigger` or `pg_class` stood in for
  the real catalog. That matters when the evaluation runs in someone else's
  session with the owner's rights -- a `SECURITY DEFINER` function that runs the
  assertion `watch()` declared, as pg_agent_gate does inside an agent's commit.
  Measured on 0.2.3 (`test/pg_temp.sh`, `make check-pgtemp`): a disabled audit
  trigger read `broken`, and `holds` once the evaluating session kept an empty
  `pg_temp.pg_trigger` or `pg_temp.pg_class`. Every function now names `pg_temp`
  last. No table changes.

## 0.2.3 -- 2026-10-06

* **License: Apache License 2.0**, replacing the PostgreSQL License, from this
  release on. Every version up to and including 0.2.2, already published,
  stays under the PostgreSQL License it was released with. No code changed.

## 0.2.2

Completes the copyright and licensing files: the copyright holder's full legal
name in LICENSE and README, and a per-file SPDX header on every SQL source
file. No schema change.

## 0.2.1

No schema change. Adds project governance and legal files (NOTICE, AUTHORS,
SECURITY, CONTRIBUTING, TRADEMARK). The database objects are byte-for-byte those
of 0.2.0; the `0.2.0--0.2.1` upgrade is empty on purpose.

## 0.2.0 and earlier

See the header of each `pg_promise_guard--*--*.sql` upgrade script and the
release notes on PGXN.
