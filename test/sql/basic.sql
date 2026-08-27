-- pg_promise_guard: the tests break the promises for real and then check that
-- the extension says so. Two things are asserted on purpose:
--
--   1. that the guarantee IS actually gone (the duplicate goes in, the audit
--      row is missing). Without this the suite would prove that the extension
--      reads the catalog, not that the catalog fact means what we claim.
--   2. that a healthy schema reports NOTHING. A checker that always finds
--      something gets ignored, and then it is not a checker.
--
-- SHOW_CONTEXT never: the CONTEXT line carries source positions that shift with
-- every edit of the SQL, and the test would break on cosmetic changes.
\set SHOW_CONTEXT never

CREATE EXTENSION pg_promise_guard;

CREATE SCHEMA pgd;

-- ===========================================================================
-- A clean schema must be silent.
-- ===========================================================================
CREATE TABLE pgd.ok (id int PRIMARY KEY, v text NOT NULL);
CREATE UNIQUE INDEX ok_v ON pgd.ok (v);
ALTER TABLE pgd.ok ADD CONSTRAINT v_no_vacio CHECK (v <> '');

SELECT count(*) AS hallazgos_en_esquema_sano FROM check_promises('pgd');
SELECT promises_kept('pgd') AS promesas_cumplidas;

-- ===========================================================================
-- PROMISE 1: "this column is unique"
-- ===========================================================================
CREATE TABLE pgd.clientes (id int, rut text);
INSERT INTO pgd.clientes VALUES (1, 'dup'), (2, 'dup');

-- The real-world shape: a migration runs this and the error scrolls past in a
-- deploy log. CONCURRENTLY is what leaves the corpse behind.
CREATE UNIQUE INDEX CONCURRENTLY clientes_rut_uk ON pgd.clientes (rut);

-- THE PREMISE, not the detection: is uniqueness actually gone?
INSERT INTO pgd.clientes VALUES (3, 'dup');
SELECT count(*) AS filas_con_el_mismo_rut FROM pgd.clientes WHERE rut = 'dup';

SELECT kind, object, severity FROM check_promises('pgd') ORDER BY kind, object;

-- ===========================================================================
-- PROMISE 2: "this CHECK is guaranteed"
-- ===========================================================================
CREATE TABLE pgd.facturas (id int, monto numeric);
INSERT INTO pgd.facturas VALUES (1, -500);
ALTER TABLE pgd.facturas ADD CONSTRAINT monto_positivo CHECK (monto > 0) NOT VALID;

SELECT count(*) AS filas_que_violan_el_check FROM pgd.facturas WHERE monto <= 0;

-- ===========================================================================
-- PROMISE 3: "the audit trigger is running"
-- ===========================================================================
CREATE TABLE pgd.auditoria (que text);
CREATE FUNCTION pgd.anotar() RETURNS trigger LANGUAGE plpgsql AS
  $$ BEGIN INSERT INTO pgd.auditoria VALUES (TG_TABLE_NAME); RETURN NEW; END $$;
CREATE TRIGGER audita AFTER INSERT ON pgd.facturas
  FOR EACH ROW EXECUTE FUNCTION pgd.anotar();

INSERT INTO pgd.facturas VALUES (2, 100);
ALTER TABLE pgd.facturas DISABLE TRIGGER audita;
INSERT INTO pgd.facturas VALUES (3, 200);

SELECT count(*) AS filas_insertadas FROM pgd.facturas WHERE monto > 0;
SELECT count(*) AS filas_auditadas FROM pgd.auditoria;

-- ===========================================================================
-- PROMISE 4: "row level security protects this table"
-- ===========================================================================
CREATE TABLE pgd.tenant_data (tenant text, dato text);
ALTER TABLE pgd.tenant_data ENABLE ROW LEVEL SECURITY;
CREATE POLICY solo_lo_mio ON pgd.tenant_data
  USING (tenant = current_setting('app.tenant', true));

-- ===========================================================================
-- The whole report
-- ===========================================================================
SELECT kind, object, relation, severity FROM check_promises('pgd')
ORDER BY severity, kind, object;

SELECT promises_kept('pgd') AS promesas_cumplidas;

-- A gap alone must NOT turn the monitor red: a NOT VALID constraint is a
-- legitimate mid-migration state, and a check that is red on purpose gets
-- silenced -- taking the real breaches with it.
CREATE SCHEMA pgd2;
CREATE TABLE pgd2.t (id int, monto numeric);
INSERT INTO pgd2.t VALUES (1, -1);
ALTER TABLE pgd2.t ADD CONSTRAINT m_pos CHECK (monto > 0) NOT VALID;
SELECT count(*) AS solo_gaps FROM check_promises('pgd2');
SELECT promises_kept('pgd2') AS sigue_verde_con_un_gap;

-- Fixing the promise must clear the finding: a checker that keeps complaining
-- after the fix is a checker that gets turned off.
ALTER TABLE pgd.facturas ENABLE TRIGGER audita;
SELECT count(*) AS triggers_apagados FROM check_promises('pgd')
WHERE kind = 'disabled_trigger';

DROP SCHEMA pgd CASCADE;
DROP SCHEMA pgd2 CASCADE;
DROP EXTENSION pg_promise_guard;
