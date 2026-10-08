-- Copyright 2026 Manuel Reyes Bravo
-- SPDX-License-Identifier: Apache-2.0

-- pg_promise_guard 0.2.3 -> 0.2.4
--
-- A temporary table of the session that EVALUATES a promise could hide a broken one.
-- check_promises() reads the catalog without a schema -- pg_index, pg_class,
-- pg_constraint, pg_trigger, pg_depend -- under search_path = promise_guard, pg_catalog.
-- pg_catalog was named and pg_temp was not, and PostgreSQL searches an unnamed pg_temp
-- FIRST for tables: a temporary pg_trigger or pg_class stood in for the real catalog.
--
-- Against oneself that is nothing. It matters when the evaluation runs in someone
-- else's session with the owner's rights: a SECURITY DEFINER function of the owner that
-- runs the assertion watch() declared -- which is what pg_agent_gate does inside an
-- agent's commit. Measured on 0.2.3 (test/pg_temp.sh): with an audit trigger disabled,
-- the promise read `broken`, and `holds` once the evaluating session kept an empty
-- pg_temp.pg_trigger or pg_temp.pg_class.
--
-- Every function now names pg_temp LAST, after pg_catalog, so a temporary table can
-- never stand in for the catalog. No table changes.

\echo Use "ALTER EXTENSION pg_promise_guard UPDATE TO '0.2.4'" to load this file. \quit

ALTER FUNCTION promise_guard.check_promises(text) SET search_path = promise_guard, pg_catalog, pg_temp;
ALTER FUNCTION promise_guard.promises_kept(text) SET search_path = promise_guard, pg_catalog, pg_temp;
ALTER FUNCTION promise_guard.watch(text) SET search_path = promise_guard, pg_catalog, pg_temp;
