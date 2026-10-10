-- Copyright 2026 Manuel Reyes Bravo
-- SPDX-License-Identifier: Apache-2.0

-- pg_promise_guard 0.2.8 -> 0.2.9
--
-- No behavior change: the names inside function bodies are English. watch()'s local variable
-- `etiqueta` is `schema_label`; nothing else changes, and CREATE OR REPLACE keeps its owner,
-- privileges and comment.

\echo Use "ALTER EXTENSION pg_promise_guard UPDATE TO '0.2.9'" to load this file. \quit

CREATE OR REPLACE FUNCTION @extschema@.watch(p_schema text DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = pg_catalog, @extschema@, pg_temp
AS $fn$
DECLARE
    schema_label text := coalesce(p_schema, '(every schema)');
    existing     bigint;
BEGIN
    -- A schema that does not exist is refused (0.2.8), before anything is declared.
    IF p_schema IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = p_schema) THEN
        RAISE EXCEPTION 'no schema named %', p_schema;
    END IF;
    -- Idempotent (0.2.8): a schema already watched keeps the assertion it has.
    SELECT a.id INTO existing FROM living_assertions.assertions a
     WHERE a.name = 'promises:' || schema_label AND a.retired_at IS NULL;
    IF existing IS NOT NULL THEN
        RETURN existing;
    END IF;
    RETURN living_assertions.declare(
        'promises:' || schema_label,
        'the guarantees the schema ' || schema_label || ' advertises are actually '
        'being enforced',
        format($f$select @extschema@.promises_kept(%L) as holds,
                         coalesce((select pg_catalog.string_agg(kind || ' on ' || object, '; ')
                                     from @extschema@.check_promises(%L)
                                    where severity = 'breach'),
                                  'no breaches') as detail$f$,
               p_schema, p_schema));
END;
$fn$;
