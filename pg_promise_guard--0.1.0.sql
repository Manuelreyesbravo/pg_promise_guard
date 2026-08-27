-- pg_promise_guard 0.1.0
--
-- Finds the guarantees your schema claims to give and silently stopped giving.
--
-- The failure this exists for: a migration runs CREATE UNIQUE INDEX
-- CONCURRENTLY, it fails on pre-existing duplicates, and it LEAVES THE INDEX
-- BEHIND -- marked unique, marked invalid. From that moment the catalog says
-- "UNIQUE" and nothing is enforced. Duplicates keep going in without an error,
-- without a log line, forever. The failure was loud exactly once, in a deploy
-- log nobody reads twice; the broken state after it is completely silent.
--
-- Same shape for a NOT VALID constraint (holds for new rows, not for the rows
-- already there) and for a trigger somebody disabled for a bulk load and never
-- re-enabled.
--
-- None of this is corruption, so amcheck will not see it: amcheck verifies that
-- a VALID index is structurally sound. These indexes are structurally fine and
-- simply not in effect.

\echo Use "CREATE EXTENSION pg_promise_guard" to load this file. \quit

-- What a broken promise looks like. Columns are stable API; kinds may grow.
CREATE TYPE promise_break AS (
    kind        text,   -- invalid_unique_index | invalid_index | not_valid_constraint
                        -- | disabled_trigger | unenforced_rls
    object      text,   -- schema-qualified name of the object
    relation    text,   -- the table whose guarantee is broken (NULL if none)
    detail      text,   -- what is not being enforced, in one sentence
    severity    text,   -- breach | gap  (see below)
    evidence    text    -- the catalog fact, so the finding can be checked by hand
);

COMMENT ON TYPE promise_break IS
    'severity=breach: something the schema states is NOT being enforced right '
    'now, and wrong data can be entering. severity=gap: the guarantee holds '
    'from here on but does not cover what was already there. The distinction '
    'matters because breach needs a fix and gap may be a deliberate migration '
    'step -- reporting both at the same level would train people to ignore both.';


-- ---------------------------------------------------------------------------
-- The scan. One pass over the catalog, no locks, no reads of user data.
-- ---------------------------------------------------------------------------
CREATE FUNCTION check_promises(p_schema text DEFAULT NULL)
RETURNS SETOF promise_break
LANGUAGE sql
STABLE
AS $$
    -- Invalid indexes. Split in two on purpose: a dead UNIQUE index is a
    -- BREACH (the uniqueness the schema advertises is not being enforced and
    -- duplicates are getting in right now), while a dead plain index is a GAP
    -- (queries are slower and writes still pay to maintain it, but no rule is
    -- being violated). Reporting them at the same severity would bury the one
    -- that lets bad data in under the ones that only cost money.
    SELECT CASE WHEN i.indisunique THEN 'invalid_unique_index'
                ELSE 'invalid_index' END,
           n.nspname || '.' || ic.relname,
           n.nspname || '.' || tc.relname,
           CASE WHEN i.indisunique
                THEN 'index is marked UNIQUE but is INVALID: uniqueness is NOT '
                     'enforced and duplicates can be inserted'
                ELSE 'index is INVALID: the planner ignores it, writes still '
                     'maintain it' END,
           CASE WHEN i.indisunique THEN 'breach' ELSE 'gap' END,
           'pg_index.indisvalid = false' ||
           CASE WHEN NOT i.indisready THEN ', indisready = false' ELSE '' END
    FROM pg_index i
    JOIN pg_class ic ON ic.oid = i.indexrelid
    JOIN pg_class tc ON tc.oid = i.indrelid
    JOIN pg_namespace n ON n.oid = ic.relnamespace
    WHERE NOT i.indisvalid
      AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
      AND (p_schema IS NULL OR n.nspname = p_schema)

    UNION ALL

    -- NOT VALID constraints. A GAP, not a breach: new rows ARE checked. It is
    -- listed because "ADD CONSTRAINT ... NOT VALID" is meant to be followed by
    -- "VALIDATE CONSTRAINT", and the second half is the one that gets forgotten
    -- -- at which point the catalog shows a constraint that does not mean what
    -- everyone reading the schema assumes it means.
    SELECT 'not_valid_constraint',
           n.nspname || '.' || c.conname,
           n.nspname || '.' || r.relname,
           'constraint is NOT VALID: it is enforced for new rows only, and the '
           'rows that already existed were never checked',
           'gap',
           -- ::text is not cosmetic: contype and tgenabled are the internal
           -- "char" type, and quote_literal has both a text and an anyelement
           -- overload, so without the cast PostgreSQL cannot pick one and the
           -- whole function errors out at call time.
           'pg_constraint.convalidated = false, contype = ' || quote_literal(c.contype::text)
    FROM pg_constraint c
    JOIN pg_class r ON r.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = c.connamespace
    WHERE NOT c.convalidated
      AND n.nspname NOT IN ('pg_catalog', 'information_schema')
      AND (p_schema IS NULL OR n.nspname = p_schema)

    UNION ALL

    -- Disabled triggers. tgenabled: O=origin (on), D=disabled, R=replica,
    -- A=always. Only 'D' is reported: R and A are deliberate replication
    -- choices, and flagging them would make this noisy on every replica -- the
    -- fastest way to teach someone to ignore the whole report.
    SELECT 'disabled_trigger',
           n.nspname || '.' || t.tgname,
           n.nspname || '.' || r.relname,
           'trigger is DISABLED: it does not run, and nothing reports that the '
           'work it used to do is no longer happening',
           'breach',
           'pg_trigger.tgenabled = ' || quote_literal(t.tgenabled::text)
    FROM pg_trigger t
    JOIN pg_class r ON r.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = r.relnamespace
    WHERE t.tgenabled = 'D'
      AND NOT t.tgisinternal
      AND n.nspname NOT IN ('pg_catalog', 'information_schema')
      AND (p_schema IS NULL OR n.nspname = p_schema)

    UNION ALL

    -- RLS enabled but not FORCED. The table owner -- and anything running as
    -- the owner, which in most applications is the application role itself --
    -- bypasses every policy. The policies exist, look right in \d, and do not
    -- apply to the one connection that matters.
    SELECT 'unenforced_rls',
           n.nspname || '.' || r.relname,
           n.nspname || '.' || r.relname,
           'row level security is ENABLED but not FORCED: the table owner '
           'bypasses every policy, so a connection that owns the table sees '
           'and writes every row',
           'breach',
           'pg_class.relrowsecurity = true, relforcerowsecurity = false'
    FROM pg_class r
    JOIN pg_namespace n ON n.oid = r.relnamespace
    WHERE r.relrowsecurity AND NOT r.relforcerowsecurity
      AND n.nspname NOT IN ('pg_catalog', 'information_schema')
      AND (p_schema IS NULL OR n.nspname = p_schema)
      -- Objects that belong to an extension are that extension's design
      -- decision, not this database's mistake. Reporting pg_cron's own tables
      -- to every user who installs pg_cron is a false positive by construction.
      AND NOT EXISTS (SELECT 1 FROM pg_depend d
                      WHERE d.objid = r.oid AND d.deptype = 'e')
$$;

COMMENT ON FUNCTION check_promises(text) IS
    'Every guarantee this database advertises and is not keeping. Reads only '
    'the system catalogs: no user data, no locks. NULL schema scans all '
    'non-system schemas.';


-- ---------------------------------------------------------------------------
-- A one-line answer for a monitoring check.
-- ---------------------------------------------------------------------------
CREATE FUNCTION promises_kept(p_schema text DEFAULT NULL)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    -- Only 'breach' decides. A 'gap' can be a migration halfway through on
    -- purpose, and a monitor that goes red for a deliberate intermediate state
    -- gets silenced -- taking the real breaches with it.
    SELECT NOT EXISTS (SELECT 1 FROM check_promises(p_schema)
                       WHERE severity = 'breach');
$$;

COMMENT ON FUNCTION promises_kept(text) IS
    'false if any guarantee is actively not being enforced (severity=breach). '
    'Deliberate gaps such as a NOT VALID constraint mid-migration do not flip '
    'it: a check that is red on purpose gets silenced, and takes the real ones '
    'with it.';


CREATE VIEW promise_breaks AS SELECT * FROM check_promises(NULL);

COMMENT ON VIEW promise_breaks IS
    'check_promises() over every non-system schema, for interactive use.';
