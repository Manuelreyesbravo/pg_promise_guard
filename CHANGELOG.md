# Changelog

Versions are released on [PGXN](https://pgxn.org/dist/pg_promise_guard/). Each
upgrade script (`pg_promise_guard--OLD--NEW.sql`) documents, in its own header,
exactly what changed and why; that is the authoritative per-version record.

## 0.2.4 -- unreleased

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
