#!/usr/bin/env bash
# Does an installation that began at 0.1.0 reach the current version, and work there?
#
# 0.1.0's control file fixed no schema, so CREATE EXTENSION put it wherever the caller said --
# usually public. 0.2.0 fixed `schema = promise_guard` for new installations; an existing one
# stays where it is. ci/upgrade_check.sh cannot see this: it installs every old version with
# the CURRENT control file, so they all land in promise_guard. Found upgrading a real database
# that began at 0.1.0: the 0.2.3 -> 0.2.4 script named promise_guard and failed there.
#
# This file reproduces the origin: 0.1.0 installed in public with ITS OWN control file (taken
# from git), then the current control file, then ALTER EXTENSION ... UPDATE.
#
#   PG_CONFIG=/path/to/pg_config test/cluster.sh init
#   PG_CONFIG=/path/to/pg_config test/cluster.sh start
#   PG_CONFIG=/path/to/pg_config test/desde_010.sh

set -euo pipefail

PG_CONFIG=${PG_CONFIG:-pg_config}
PSQL=${PSQL:-$("$PG_CONFIG" --bindir)/psql}
RAIZ=$(cd "$(dirname "$0")/.." && pwd)
export PGHOST=${PGHOST:-$RAIZ/.testcluster} PGPORT=${PGPORT:-5495}
CONTROL=$PGHOST/ext/extension/pg_promise_guard.control
BASE=promise_guard_test_desde_010
TENANT=promise_guard_test_desde_010_tenant
failures=0

[ -L "$CONTROL" ] || { echo "no control link at $CONTROL: run test/cluster.sh init and start first" >&2; exit 2; }
if [ "$($PSQL -X -d postgres -tAc "select 1 from pg_roles where rolname = '$TENANT'")" = 1 ]; then
    echo "a role named $TENANT already exists: not dropping what this script did not create" >&2
    exit 2
fi
if [ "$($PSQL -X -d postgres -tAc "select 1 from pg_database where datname = '$BASE'")" = 1 ]; then
    echo "a database named $BASE already exists: not dropping what this script did not create" >&2
    exit 2
fi
restore() {
    rm -f "$CONTROL" && ln -s "$RAIZ/pg_promise_guard.control" "$CONTROL"
    $PSQL -X -d postgres -qc "drop database if exists $BASE" -c "drop role if exists $TENANT" >/dev/null 2>&1 || true
}
trap restore EXIT
$PSQL -X -d postgres -qc "create database $BASE"

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

# 0.1.0 with the control file it shipped with: no schema, so it goes to public.
rm -f "$CONTROL"
git -C "$RAIZ" show b650233^:pg_promise_guard.control > "$CONTROL"
$PSQL -X -d "$BASE" -q -v ON_ERROR_STOP=1 -c "create extension pg_promise_guard version '0.1.0' schema public"
check "0.1.0 installed in public, as it was" "public" \
    "$($PSQL -X -d "$BASE" -tAc "select extnamespace::regnamespace from pg_extension where extname = 'pg_promise_guard'")"

# Today's control file, and the update a user runs.
rm -f "$CONTROL" && ln -s "$RAIZ/pg_promise_guard.control" "$CONTROL"
want=$(sed -n "s/^default_version *= *'\(.*\)'/\1/p" "$RAIZ/pg_promise_guard.control")
$PSQL -X -d "$BASE" -tA -c "create extension if not exists pg_living_assertions" \
    -c "alter extension pg_promise_guard update" 2>&1 || true
# The version EXACTLY, and asked separately: the first version of this check matched "$want" as a
# substring of the whole output, and the error of a failed update names the script file
# (...--0.2.3--0.2.4.sql), so a failure read as success.
got=$($PSQL -X -d "$BASE" -tAc "select extversion from pg_extension where extname = 'pg_promise_guard'" 2>&1 || true)
if [ "$got" = "$want" ]; then
    echo "  ok   ALTER EXTENSION UPDATE reaches $want from an installation in public"
else
    echo "  FAIL ALTER EXTENSION UPDATE reaches $want from an installation in public"
    echo "       got:      $got"
    failures=$((failures + 1))
fi

check "every function searches pg_catalog first and pg_temp last, in the schema it is actually in" "3" \
    "$($PSQL -X -d "$BASE" -tAc "select count(*) from pg_proc p join pg_depend d on d.objid = p.oid and d.deptype = 'e' join pg_extension e on e.oid = d.refobjid and e.extname = 'pg_promise_guard' where p.proconfig @> array['search_path=pg_catalog, public, pg_temp']")"

# watch() has to declare an assertion that RUNS there -- since 0.2.0 it named promise_guard.
$PSQL -X -d "$BASE" -q -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
CREATE SCHEMA app;
CREATE TABLE app.orders (id int);
CREATE FUNCTION app.audit() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$;
CREATE TRIGGER audit AFTER INSERT ON app.orders FOR EACH ROW EXECUTE FUNCTION app.audit();
ALTER TABLE app.orders DISABLE TRIGGER audit;
SELECT public.watch('app');
SQL
check "the assertion watch() declares runs, and sees the disabled trigger" "broken" \
    "$($PSQL -X -d "$BASE" -tAc "select state from living_assertions.status where name = 'promises:app'" 2>&1 || true)"

# PG-01 (external audit of 0.2.5): the extension's schema came BEFORE pg_catalog on its path,
# and here that schema is public. A role that may create in public made public.pg_trigger and
# public.pg_index, empty, and the scanner read them instead of the catalog: no finding,
# promises_kept() true, and the assertion watch() declared said holds.
$PSQL -X -d "$BASE" -q -c "create role $TENANT login" -c "grant create on schema public to $TENANT" >/dev/null
PGUSER=$TENANT $PSQL -X -d "$BASE" -q -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
CREATE TABLE public.pg_index (indexrelid oid, indrelid oid, indisvalid bool, indisunique bool, indisready bool);
CREATE TABLE public.pg_trigger (tgrelid oid, tgname name, tgenabled "char", tgisinternal bool);
SQL
check "control: the empty copies of pg_trigger and pg_index are in public" "2" \
    "$($PSQL -X -d "$BASE" -tAc "select count(*) from pg_class where relnamespace = 'public'::regnamespace and relname in ('pg_trigger', 'pg_index')")"
check "check_promises() still reads the real catalog: the disabled trigger" "app.audit" \
    "$($PSQL -X -d "$BASE" -tAc "select object from public.check_promises('app')" 2>&1 || true)"
check "  ...promises_kept() is false" "f" \
    "$($PSQL -X -d "$BASE" -tAc "select public.promises_kept('app')" 2>&1 || true)"
check "  ...and the watched assertion stays broken" "broken" \
    "$($PSQL -X -d "$BASE" -tAc "select (living_assertions.run('promises:app')).state" 2>&1 || true)"

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "an installation that began at 0.1.0 reaches the current version and works there"
