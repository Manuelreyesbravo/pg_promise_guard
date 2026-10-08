#!/usr/bin/env bash
# Can the session that EVALUATES a promise hide a broken one?
#
# check_promises() reads the catalog without a schema -- pg_index, pg_class,
# pg_constraint, pg_trigger -- under search_path = promise_guard, pg_catalog.
# pg_catalog is named and pg_temp is not, and PostgreSQL searches an unnamed
# pg_temp FIRST for tables: a temporary table called pg_trigger in the session
# that evaluates stands in for the real catalog.
#
# Against oneself that is nothing. It matters when the evaluation runs in
# SOMEONE ELSE's session with the owner's rights: a SECURITY DEFINER function of
# the owner that runs the assertion watch() declared -- which is what
# pg_agent_gate does inside an agent's commit. An agent allowed DDL disables a
# trigger, keeps an empty pg_temp.pg_trigger, and the assertion says `holds`.
#
# BOTH HALVES: without the temporary table the promise reads broken (the
# instrument can say red), and with it too.
#
#   PG_CONFIG=/path/to/pg_config test/cluster.sh init
#   PG_CONFIG=/path/to/pg_config test/cluster.sh start
#   PG_CONFIG=/path/to/pg_config test/pg_temp.sh

set -euo pipefail

PG_CONFIG=${PG_CONFIG:-pg_config}
PSQL=${PSQL:-$("$PG_CONFIG" --bindir)/psql}
RAIZ=$(cd "$(dirname "$0")/.." && pwd)
export PGHOST=${PGHOST:-$RAIZ/.testcluster} PGPORT=${PGPORT:-5495}
BASE=promise_guard_test_pg_temp
OTHER=promise_guard_test_pg_temp_other
failures=0

for what in "database:$BASE" "role:$OTHER"; do
    kind=${what%%:*}; name=${what#*:}
    q="select 1 from pg_database where datname = '$name'"
    [ "$kind" = role ] && q="select 1 from pg_roles where rolname = '$name'"
    if [ "$($PSQL -X -d postgres -tAc "$q")" = 1 ]; then
        echo "a $kind named $name already exists: not dropping what this script did not create" >&2
        exit 2
    fi
done
trap '$PSQL -X -d postgres -qc "drop database if exists $BASE" -c "drop role if exists $OTHER" >/dev/null 2>&1 || true' EXIT
$PSQL -X -d postgres -qc "create database $BASE" -c "create role $OTHER login"

$PSQL -X -d "$BASE" -q -v ON_ERROR_STOP=1 -v other="$OTHER" >/dev/null <<'SQL'
CREATE EXTENSION pg_promise_guard CASCADE;
CREATE SCHEMA app;
CREATE TABLE app.orders (id int);
CREATE FUNCTION app.audit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$;
CREATE TRIGGER audit AFTER INSERT ON app.orders FOR EACH ROW EXECUTE FUNCTION app.audit();
-- The promise the schema stopped keeping: its audit trigger is disabled.
ALTER TABLE app.orders DISABLE TRIGGER audit;
SELECT promise_guard.watch('app');
-- The pattern of pg_agent_gate: the owner runs the assertion on someone else's behalf.
CREATE FUNCTION public.evaluate(p text) RETURNS text LANGUAGE sql SECURITY DEFINER
    SET search_path = pg_catalog
    AS $$ SELECT (living_assertions.run(p)).state $$;
REVOKE ALL ON FUNCTION public.evaluate(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.evaluate(text) TO :"other";
SQL

check() {
    local what="$1" expected="$2" got="$3"
    if [[ "$got" == *"$expected"* ]]; then
        echo "  ok   $what"
    else
        echo "  FAIL $what"
        echo "       expected: $expected"
        echo "       got:      ${got//$'\n'/ }"
        failures=$((failures + 1))
    fi
}

check "without a temporary table, the disabled trigger reads as a broken promise" "broken" \
    "$(PGUSER=$OTHER $PSQL -X -d "$BASE" -tAc "select evaluate('promises:app')" 2>&1 || true)"

# THE CASE: the same session keeps an empty pg_temp.pg_trigger and asks again.
check "a temporary pg_trigger in the evaluating session does NOT hide it" "broken" \
    "$(PGUSER=$OTHER $PSQL -X -d "$BASE" -tA \
        -c "create temp table pg_trigger (tgrelid oid, tgname name, tgenabled \"char\", tgisinternal bool)" \
        -c "select evaluate('promises:app')" 2>&1 || true)"

check "nor a temporary pg_class" "broken" \
    "$(PGUSER=$OTHER $PSQL -X -d "$BASE" -tA \
        -c "create temp table pg_class (oid oid, relname name, relnamespace oid, relrowsecurity bool, relforcerowsecurity bool)" \
        -c "select evaluate('promises:app')" 2>&1 || true)"

check "and the owner, in its own session, still sees it" "f" \
    "$($PSQL -X -d "$BASE" -tAc "select promise_guard.promises_kept('app')" 2>&1 || true)"

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "a temporary table of whoever evaluates does not hide a broken promise"
