-- Copyright 2026 Manuel Reyes Bravo
-- SPDX-License-Identifier: Apache-2.0

-- pg_promise_guard 0.2.7 -> 0.2.8
--
-- The Medium and Low findings of the external audit of 0.2.5 left open, each measured on 0.2.7 first
-- (test/audit.sh: every tooth red there with its control green).
--
--   * PG-02: an object that belongs to an extension was skipped -- and any role with CREATE on the
--     database can create a trusted extension and add its own table to it, hiding unenforced_rls.
--     Only extensions owned by a superuser are skipped now, in every branch (the README said every
--     branch; only the RLS one did it).
--   * PG-03: a NOT ENFORCED constraint (PostgreSQL 18) is not checked for any row, and read as a gap
--     "enforced for new rows only". It is a breach of its own kind now.
--   * PG-04: a trigger set to fire only in replica mode is reported (a gap: it can be a replication
--     choice, and it is silent in every normal session); a disabled foreign-key trigger is a breach.
--   * PG-05: a policy on a table without row level security, a disabled rule and a disabled event
--     trigger are breaches; a NOT VALID domain constraint is a gap, like a table's.
--   * PG-06: a schema that does not exist read as "no breaches". It raises now, in check_promises(),
--     promises_kept() and watch().
--   * PG-07: under REPEATABLE READ the check read the catalog as it was when the transaction began,
--     and the assertion recorded holds after a breach. It refuses outside READ COMMITTED.
--   * PG-08: a CREATE UNIQUE INDEX CONCURRENTLY in progress read as a breach on every deploy. An index
--     being built is a gap now (PostgreSQL 12 and later report the build; 11 cannot).
--   * PG-09: a UNIQUE index that is invalid but ready -- a concurrent build cancelled after its first
--     phase -- enforces uniqueness for new rows, and the detail said duplicates can be inserted. It is
--     a gap now, saying what is true: new rows are checked, rows that existed were not.
--   * PG-10: row level security not forced is a breach when the table's owner can log in; when it
--     cannot, it is a gap -- a member can still SET ROLE to it, which is why it is still reported.
--   * PG-11: watch() of a schema already watched returns the assertion it has, instead of failing.

\echo Use "ALTER EXTENSION pg_promise_guard UPDATE TO '0.2.8'" to load this file. \quit

CREATE OR REPLACE FUNCTION @extschema@.check_promises(p_schema text DEFAULT NULL)
RETURNS SETOF @extschema@.promise_break
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, @extschema@, pg_temp
AS $fn$
DECLARE
    building oid[] := '{}';
BEGIN
    -- The catalog as it is now (0.2.8): under REPEATABLE READ it is the catalog when the transaction
    -- began, and a breach made since reads as kept -- and is recorded as kept.
    IF current_setting('transaction_isolation') <> 'read committed' THEN
        RAISE EXCEPTION 'pg_promise_guard reads the catalog as it is now: run it under read committed, not %',
            current_setting('transaction_isolation');
    END IF;
    -- A schema that does not exist has no breaches and keeps no promises (0.2.8): saying "clean" for a
    -- typo is the failure this extension exists to prevent.
    IF p_schema IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = p_schema) THEN
        RAISE EXCEPTION 'no schema named %', p_schema;
    END IF;
    -- Indexes being built right now (0.2.8), where PostgreSQL reports it (12 and later).
    IF to_regclass('pg_catalog.pg_stat_progress_create_index') IS NOT NULL THEN
        EXECUTE 'SELECT coalesce(array_agg(index_relid), ''{}'') FROM pg_catalog.pg_stat_progress_create_index'
            INTO building;
    END IF;

    RETURN QUERY
    WITH
    -- Objects of an extension owned by a superuser are that extension's design, not this database's
    -- mistake. An extension a tenant created and owns is not (0.2.8).
    ext_owned(classid, objid) AS (
        SELECT d.classid, d.objid
          FROM pg_depend d
          JOIN pg_extension e ON d.refclassid = 'pg_extension'::regclass AND e.oid = d.refobjid
          JOIN pg_roles o ON o.oid = e.extowner
         WHERE d.deptype = 'e' AND o.rolsuper
    ),
    rels AS (
        SELECT r.oid, r.relname, r.relowner, r.relrowsecurity, r.relforcerowsecurity, n.nspname
          FROM pg_class r JOIN pg_namespace n ON n.oid = r.relnamespace
         WHERE n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
           AND n.nspname NOT LIKE 'pg\_temp\_%' AND n.nspname NOT LIKE 'pg\_toast\_temp\_%'
           AND (p_schema IS NULL OR n.nspname = p_schema)
           AND NOT EXISTS (SELECT 1 FROM ext_owned x WHERE x.classid = 'pg_class'::regclass AND x.objid = r.oid)
    )
    -- Invalid indexes. A dead UNIQUE index is a BREACH (duplicates get in now); one that is ready
    -- enforces uniqueness for new rows, so it is a GAP like a NOT VALID constraint (0.2.8); one being
    -- built right now is a GAP (0.2.8); a dead plain index is a GAP.
    SELECT CASE WHEN i.indexrelid = ANY (building) THEN 'index_being_built'
                WHEN i.indisunique AND i.indisready THEN 'unique_index_not_valid'
                WHEN i.indisunique THEN 'invalid_unique_index'
                ELSE 'invalid_index' END,
           format('%I.%I', t.nspname, ic.relname),
           format('%I.%I', t.nspname, t.relname),
           CASE WHEN i.indexrelid = ANY (building)
                THEN 'index is being built (CREATE INDEX CONCURRENTLY in progress): it is not in effect until the build ends'
                WHEN i.indisunique AND i.indisready
                THEN 'UNIQUE index is INVALID but ready: new rows are checked for uniqueness, the rows '
                     'that existed when it was built were never checked, and the planner does not use it'
                WHEN i.indisunique
                THEN 'index is marked UNIQUE but is INVALID: uniqueness is NOT enforced and duplicates can be inserted'
                ELSE 'index is INVALID: the planner ignores it, writes still maintain it' END,
           CASE WHEN i.indisunique AND NOT i.indisready AND NOT (i.indexrelid = ANY (building)) THEN 'breach'
                ELSE 'gap' END,
           'pg_index.indisvalid = false' || CASE WHEN NOT i.indisready THEN ', indisready = false' ELSE '' END
      FROM pg_index i
      JOIN pg_class ic ON ic.oid = i.indexrelid
      JOIN rels t ON t.oid = i.indrelid
     WHERE NOT i.indisvalid

    UNION ALL

    -- NOT ENFORCED constraints (PostgreSQL 18): checked for no row at all (0.2.8). Read through
    -- to_jsonb so the column, absent before 18, is not named.
    SELECT 'not_enforced_constraint',
           format('%I.%I', t.nspname, c.conname),
           format('%I.%I', t.nspname, t.relname),
           'constraint is NOT ENFORCED: it is checked for no row, old or new',
           'breach',
           'pg_constraint.conenforced = false, contype = ' || quote_literal(c.contype::text)
      FROM pg_constraint c
      JOIN rels t ON t.oid = c.conrelid
     WHERE (to_jsonb(c) ->> 'conenforced') = 'false'

    UNION ALL

    -- NOT VALID constraints: a GAP, new rows ARE checked.
    SELECT 'not_valid_constraint',
           format('%I.%I', t.nspname, c.conname),
           format('%I.%I', t.nspname, t.relname),
           'constraint is NOT VALID: it is enforced for new rows only, and the rows that already '
           'existed were never checked',
           'gap',
           'pg_constraint.convalidated = false, contype = ' || quote_literal(c.contype::text)
      FROM pg_constraint c
      JOIN rels t ON t.oid = c.conrelid
     WHERE NOT c.convalidated
       AND coalesce(to_jsonb(c) ->> 'conenforced', 'true') <> 'false'

    UNION ALL

    -- NOT VALID domain constraints (0.2.8): the same gap, on a type instead of a table.
    SELECT 'not_valid_domain_constraint',
           format('%I.%I', n.nspname, c.conname),
           format('%I.%I', n.nspname, ty.typname),
           'domain constraint is NOT VALID: values stored before it was added were never checked',
           'gap',
           'pg_constraint.convalidated = false on domain ' || quote_literal(ty.typname::text)
      FROM pg_constraint c
      JOIN pg_type ty ON ty.oid = c.contypid
      JOIN pg_namespace n ON n.oid = ty.typnamespace
     WHERE c.contypid <> 0 AND NOT c.convalidated
       AND n.nspname NOT IN ('pg_catalog', 'information_schema')
       AND (p_schema IS NULL OR n.nspname = p_schema)
       AND NOT EXISTS (SELECT 1 FROM ext_owned x WHERE x.classid = 'pg_type'::regclass AND x.objid = ty.oid)

    UNION ALL

    -- Triggers that do not fire in a normal session. A user trigger DISABLED is a breach; a
    -- foreign-key trigger disabled (DISABLE TRIGGER ALL) is a breach too -- orphans get in (0.2.8);
    -- one that fires only in replica mode is a gap: it can be a replication choice (0.2.8).
    SELECT CASE WHEN tg.tgenabled = 'R' THEN 'replica_only_trigger'
                WHEN tg.tgisinternal THEN 'disabled_fk_trigger'
                ELSE 'disabled_trigger' END,
           format('%I.%I', t.nspname, tg.tgname),
           format('%I.%I', t.nspname, t.relname),
           CASE WHEN tg.tgenabled = 'R'
                THEN 'trigger fires only when session_replication_role = replica: in every normal '
                     'session it does not run'
                WHEN tg.tgisinternal
                THEN 'foreign-key trigger is DISABLED: the constraint is not checked, and rows that '
                     'break it can be inserted'
                ELSE 'trigger is DISABLED: it does not run, and nothing reports that the work it used '
                     'to do is no longer happening' END,
           CASE WHEN tg.tgenabled = 'R' THEN 'gap' ELSE 'breach' END,
           'pg_trigger.tgenabled = ' || quote_literal(tg.tgenabled::text)
      FROM pg_trigger tg
      JOIN rels t ON t.oid = tg.tgrelid
     WHERE (tg.tgenabled = 'D' AND (NOT tg.tgisinternal OR tg.tgconstraint <> 0))
        OR (tg.tgenabled = 'R' AND NOT tg.tgisinternal)

    UNION ALL

    -- RLS enabled but not FORCED. A breach when the owner can log in (it, and the application
    -- running as it, bypass every policy); a gap when it cannot (0.2.8) -- a member may still SET ROLE.
    SELECT 'unenforced_rls',
           format('%I.%I', t.nspname, t.relname),
           format('%I.%I', t.nspname, t.relname),
           CASE WHEN o.rolcanlogin
                THEN 'row level security is ENABLED but not FORCED: the table owner bypasses every '
                     'policy, so a connection that owns the table sees and writes every row'
                ELSE 'row level security is ENABLED but not FORCED; the owner cannot log in, but a role '
                     'that may SET ROLE to it bypasses every policy' END,
           CASE WHEN o.rolcanlogin THEN 'breach' ELSE 'gap' END,
           'pg_class.relrowsecurity = true, relforcerowsecurity = false'
      FROM rels t
      JOIN pg_roles o ON o.oid = t.relowner
     WHERE t.relrowsecurity AND NOT t.relforcerowsecurity

    UNION ALL

    -- Policies on a table whose row level security is off (0.2.8): they look right and apply to nobody.
    SELECT 'policy_without_rls',
           format('%I.%I', t.nspname, t.relname),
           format('%I.%I', t.nspname, t.relname),
           'the table has policies but row level security is NOT ENABLED: no policy applies',
           'breach',
           'pg_policy rows = ' || count(*)::text || ', pg_class.relrowsecurity = false'
      FROM rels t
      JOIN pg_policy p ON p.polrelid = t.oid
     WHERE NOT t.relrowsecurity
     GROUP BY t.nspname, t.relname

    UNION ALL

    -- Disabled rules (0.2.8).
    SELECT 'disabled_rule',
           format('%I.%I', t.nspname, rw.rulename),
           format('%I.%I', t.nspname, t.relname),
           'rule is DISABLED: what it did on every write no longer happens',
           'breach',
           'pg_rewrite.ev_enabled = ' || quote_literal(rw.ev_enabled::text)
      FROM pg_rewrite rw
      JOIN rels t ON t.oid = rw.ev_class
     WHERE rw.ev_enabled = 'D' AND rw.rulename <> '_RETURN'

    UNION ALL

    -- Disabled event triggers (0.2.8): database-wide, so only in the report of every schema.
    SELECT 'disabled_event_trigger',
           format('%I', e.evtname),
           NULL::text,
           'event trigger is DISABLED: what it did on every DDL command no longer happens',
           'breach',
           'pg_event_trigger.evtenabled = ' || quote_literal(e.evtenabled::text)
      FROM pg_event_trigger e
     WHERE e.evtenabled = 'D' AND p_schema IS NULL
       AND NOT EXISTS (SELECT 1 FROM ext_owned x WHERE x.classid = 'pg_event_trigger'::regclass AND x.objid = e.oid);
END;
$fn$;

CREATE OR REPLACE FUNCTION @extschema@.watch(p_schema text DEFAULT NULL)
RETURNS bigint
LANGUAGE plpgsql
SET search_path = pg_catalog, @extschema@, pg_temp
AS $fn$
DECLARE
    etiqueta text := coalesce(p_schema, '(every schema)');
    existing bigint;
BEGIN
    -- A schema that does not exist is refused (0.2.8), before anything is declared.
    IF p_schema IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = p_schema) THEN
        RAISE EXCEPTION 'no schema named %', p_schema;
    END IF;
    -- Idempotent (0.2.8): a schema already watched keeps the assertion it has.
    SELECT a.id INTO existing FROM living_assertions.assertions a
     WHERE a.name = 'promises:' || etiqueta AND a.retired_at IS NULL;
    IF existing IS NOT NULL THEN
        RETURN existing;
    END IF;
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
