-- Copyright 2026 Manuel Reyes Bravo
-- SPDX-License-Identifier: Apache-2.0

-- pg_promise_guard 0.1.0 -> 0.2.0
--
-- Adds watch(): the scan gets a memory, from pg_living_assertions.
--
-- NOTHING IS REMOVED AND NOTHING CHANGES BEHAVIOUR. check_promises(),
-- promises_kept() and promise_breaks answer exactly what they answered in
-- 0.1.0. This extension had no baseline, no approve() and no drift of its own
-- to move -- which is precisely why it is the interesting consumer: if the
-- piece only fitted extensions that already had those, it would not be an
-- abstraction, it would be a baselines library.

\echo Use "ALTER EXTENSION pg_promise_guard UPDATE TO '0.2.0'" to load this file. \quit

-- FIRST, A DEFECT THAT WAS LATENT IN 0.1.0. Neither function set its own
-- search_path, so both resolved through the CALLER's -- meaning they only
-- worked from a session that already had promise_guard in scope. A cron job, a
-- monitoring role or a SECURITY DEFINER context got "function
-- check_promises(text) does not exist", and an unqualified name can also
-- resolve to something a user planted earlier in their path.
--
-- Found by putting this extension on pg_living_assertions, whose evaluator runs
-- the stored check under its own search_path. No test had caught it because
-- every test called these from a session that had the schema in scope.
-- @extschema@ and NOT the schema name written by hand. The REAL installation
-- exposed this: in that database pg_promise_guard lives in `public`, not in
-- `promise_guard`, so pinning the search_path to the literal name left
-- promises_kept() searching a schema that does not exist -- and the first version
-- of this upgrade BROKE an installation that used to work. Fixing the
-- search_path with the wrong name is worse than not fixing it.
ALTER FUNCTION check_promises(text) SET search_path = @extschema@, pg_catalog;
ALTER FUNCTION promises_kept(text)  SET search_path = @extschema@, pg_catalog;

CREATE FUNCTION watch(p_schema text DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = @extschema@, pg_catalog
AS $$
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
$$;

COMMENT ON FUNCTION watch(text) IS
    'Registers the breach scan for this schema as a living assertion, so it '
    'carries the date it was last run and what it said last time. Only breaches '
    'decide the verdict -- a deliberate gap mid-migration must not turn it red, '
    'for the same reason promises_kept() ignores them. The gaps still show in '
    'check_promises(), where they belong.';
