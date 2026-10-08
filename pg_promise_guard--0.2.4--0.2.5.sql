-- Copyright 2026 Manuel Reyes Bravo
-- SPDX-License-Identifier: Apache-2.0

-- pg_promise_guard 0.2.4 -> 0.2.5
--
-- An installation that began at 0.1.0 lives outside the promise_guard schema. 0.1.0's control
-- file fixed no schema, so CREATE EXTENSION put it wherever the caller said -- usually public;
-- 0.2.0 fixed `schema = promise_guard` for new installations, but an existing one stays where
-- it is. The 0.2.3 -> 0.2.4 script named promise_guard literally (ALTER FUNCTION
-- promise_guard....) and failed there with `schema "promise_guard" does not exist` -- found
-- upgrading a real database that began at 0.1.0; the failure was all or nothing. The script
-- now says @extschema@, as 0.1.0 -> 0.2.0 always did.
--
-- watch() is recreated naming @extschema@, pg_temp last. The published 0.1.0 -> 0.2.0 already
-- wrote it that way; the same database carried a watch() naming promise_guard literally, from a
-- build before that release, and this normalizes it. On an installation in promise_guard
-- nothing changes. test/desde_010.sh reproduces the origin:
-- 0.1.0 installed with its own control file, then updated to this version.

\echo Use "ALTER EXTENSION pg_promise_guard UPDATE TO '0.2.5'" to load this file. \quit

CREATE OR REPLACE FUNCTION @extschema@.watch(p_schema text DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog, pg_temp
AS $fn$
DECLARE
    etiqueta text := coalesce(p_schema, '(every schema)');
BEGIN
    RETURN living_assertions.declare(
        'promises:' || etiqueta,
        'the guarantees the schema ' || etiqueta || ' advertises are actually '
        'being enforced',
        format($f$select @extschema@.promises_kept(%L) as holds,
                         coalesce((select string_agg(kind || ' on ' || object, '; ')
                                     from @extschema@.check_promises(%L)
                                    where severity = 'breach'),
                                  'no breaches') as detail$f$,
               p_schema, p_schema));
END;
$fn$;
