-- Copyright 2026 Manuel Reyes Bravo
-- SPDX-License-Identifier: Apache-2.0

-- pg_promise_guard 0.2.6 -> 0.2.7
--
-- PG-01 (external audit of 0.2.5): every function searched its own schema BEFORE pg_catalog.
-- In promise_guard that schema is the extension's; in an installation that began at 0.1.0 it
-- is public, where any role with CREATE -- the default before PostgreSQL 15, and in any
-- database that came through pg_upgrade with that grant -- can create a table named
-- pg_trigger or pg_index. Measured (test/desde_010.sh): two empty such tables in public and
-- check_promises() found nothing, promises_kept() said true, and the assertion watch()
-- declared recorded holds over a disabled trigger. 0.2.4 put pg_temp last; that covered
-- temporary tables and not this.
--
-- Every function now searches pg_catalog first. watch() also qualifies what the check it
-- declares calls, and declares it under that path, so the assertion it records reads the
-- catalog too. An assertion watch() declared before 0.2.7 keeps the path it was declared
-- with: this script names them; retire and watch() again to move them.

\echo Use "ALTER EXTENSION pg_promise_guard UPDATE TO '0.2.7'" to load this file. \quit

ALTER FUNCTION @extschema@.check_promises(text) SET search_path = pg_catalog, @extschema@, pg_temp;
ALTER FUNCTION @extschema@.promises_kept(text) SET search_path = pg_catalog, @extschema@, pg_temp;

CREATE OR REPLACE FUNCTION @extschema@.watch(p_schema text DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = pg_catalog, @extschema@, pg_temp
AS $fn$
DECLARE
    etiqueta text := coalesce(p_schema, '(every schema)');
BEGIN
    RETURN living_assertions.declare(
        'promises:' || etiqueta,
        'the guarantees the schema ' || etiqueta || ' advertises are actually '
        'being enforced',
        format($f$select @extschema@.promises_kept(%L) as holds,
                         coalesce((select pg_catalog.string_agg(kind || ' on ' || object, '; ')
                                     from @extschema@.check_promises(%L)
                                    where severity = 'breach'),
                                  'no breaches') as detail$f$,
               p_schema, p_schema));
END;
$fn$;

DO $$
DECLARE
    names text;
BEGIN
    IF to_regclass('living_assertions.assertions') IS NULL THEN
        RETURN;
    END IF;
    EXECUTE $q$
        SELECT string_agg(name, ', ' ORDER BY name) FROM living_assertions.assertions
         WHERE retired_at IS NULL AND name LIKE 'promises:%'
           AND search_path NOT LIKE 'pg_catalog%'$q$ INTO names;
    IF names IS NOT NULL THEN
        RAISE WARNING 'pg_promise_guard: these watches were declared under a path that searches the extension''s schema before pg_catalog: %', names
            USING HINT = 'Retire each one (living_assertions.retire) and call watch() again.';
    END IF;
END $$;
