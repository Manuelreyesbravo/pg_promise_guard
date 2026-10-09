#!/usr/bin/env bash
# The Medium and Low findings of the external audit of 0.2.5 that this repo closed, each against its
# control -- the proof that the instrument can answer the other way.
#
#   PG-02 a role with CREATE on the database hid unenforced_rls by adding its table to an extension
#   PG-03 a NOT ENFORCED constraint (PostgreSQL 18) read as a gap that is "enforced for new rows"
#   PG-04 a trigger set to fire only in replica mode, and disabled foreign-key triggers, read clean
#   PG-05 a policy on a table without RLS, a disabled rule, a disabled event trigger and a NOT VALID
#         domain constraint read clean
#   PG-06 a schema that does not exist read as "no breaches"
#   PG-07 under REPEATABLE READ the check read an old catalog and recorded holds after a breach
#   PG-09 a UNIQUE index that is invalid but ready -- uniqueness enforced for new rows -- was a breach
#         that said duplicates can be inserted
#   PG-10 RLS not forced read as a breach when the table owner cannot log in
#   PG-11 watch() twice on one schema failed with a duplicate key
#
# Run against the throwaway cluster: test/cluster.sh init && test/cluster.sh start.

set -euo pipefail

PG_CONFIG=${PG_CONFIG:-pg_config}
PSQL=${PSQL:-$("$PG_CONFIG" --bindir)/psql}
RAIZ=$(cd "$(dirname "$0")/.." && pwd)
export PGHOST=${PGHOST:-$RAIZ/.testcluster} PGPORT=${PGPORT:-5495}
DB=promise_guard_test_audit
TENANT=promise_guard_test_audit_tenant
OWNER=promise_guard_test_audit_owner
failures=0

for what in "database:$DB" "role:$TENANT" "role:$OWNER"; do
    kind=${what%%:*}; name=${what#*:}
    q="select 1 from pg_database where datname = '$name'"
    [ "$kind" = role ] && q="select 1 from pg_roles where rolname = '$name'"
    if [ "$($PSQL -X -d postgres -tAc "$q")" = 1 ]; then
        echo "a $kind named $name already exists: not dropping what this script did not create" >&2
        exit 2
    fi
done
cleanup() {
    $PSQL -X -d "$DB" -qc "drop event trigger if exists promise_guard_test_audit_evt" >/dev/null 2>&1 || true
    $PSQL -X -d postgres -qc "drop database if exists $DB" -c "drop role if exists $TENANT" -c "drop role if exists $OWNER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

q()  { $PSQL -X -d "$DB" -tA "$@" 2>&1 || true; }
qt() { PGUSER=$TENANT $PSQL -X -d "$DB" -tA "$@" 2>&1 || true; }
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
findings() { q -c "select kind || '|' || severity from promise_guard.check_promises('$1') order by 1"; }

$PSQL -X -d postgres -qc "create database $DB" -c "create role $TENANT login" -c "create role $OWNER nologin" -c "grant create on database $DB to $TENANT"
q -q -c "create extension pg_promise_guard cascade" >/dev/null

echo "PG-02: adding a table to an extension does not hide it"
qt -q -c "create schema tn" -c "create table tn.secrets (tenant text, d text)" -c "alter table tn.secrets enable row level security" >/dev/null
check "control: the tenant's table reads unenforced_rls" "unenforced_rls|breach" "$(findings tn)"
qt -q -c "create extension citext schema tn" -c "alter extension citext add table tn.secrets" >/dev/null
check "after the tenant adds it to an extension it owns, it still does" "unenforced_rls|breach" "$(findings tn)"

echo "PG-03: a NOT ENFORCED constraint is a breach"
if [ "$(q -c "select current_setting('server_version_num')::int >= 180000")" = t ]; then
    q -q -c "create schema ta" -c "create table ta.t (m int)" -c "alter table ta.t add constraint pos check (m > 0) not enforced" >/dev/null
    check "control: a row that breaks it goes in" "INSERT 0 1" "$(q -c "insert into ta.t values (-5)")"
    check "the constraint reads as a breach" "not_enforced_constraint|breach" "$(findings ta)"
else
    echo "  --   PostgreSQL before 18 has no NOT ENFORCED constraints"
fi

echo "PG-04: triggers that do not fire in a normal session"
q -q -c "create schema tb" -c "create table tb.p (id int primary key)" -c "create table tb.c (p int references tb.p)" \
     -c "create function tb.audit() returns trigger language plpgsql as \$\$ begin return new; end \$\$" \
     -c "create trigger audit after insert on tb.p for each row execute function tb.audit()" >/dev/null
check "control: nothing reported" "count=0" "$(q -c "select 'count=' || count(*) from promise_guard.check_promises('tb')")"
q -q -c "alter table tb.p enable replica trigger audit" >/dev/null
check "a trigger that fires only in replica mode is reported" "replica_only_trigger|gap" "$(findings tb)"
q -q -c "alter table tb.c disable trigger all" >/dev/null
check "disabled foreign-key triggers are a breach" "disabled_fk_trigger|breach" "$(findings tb)"

echo "PG-05: promises broken by an object that is switched off"
q -q -c "create schema tp" -c "create table tp.s (owner text)" -c "create policy only_mine on tp.s using (owner = current_user)" \
     -c "create table tp.r (x int)" -c "create table tp.rlog (x int)" -c "create rule logit as on insert to tp.r do also insert into tp.rlog values (new.x)" \
     -c "alter table tp.r disable rule logit" \
     -c "create domain tp.dpos as int" -c "alter domain tp.dpos add constraint dp check (value > 0) not valid" >/dev/null
f=$(findings tp)
check "a policy on a table without row level security is a breach" "policy_without_rls|breach" "$f"
check "a disabled rule is a breach" "disabled_rule|breach" "$f"
check "a NOT VALID domain constraint is a gap" "not_valid_domain_constraint|gap" "$f"
q -q -c "create function public.evt() returns event_trigger language plpgsql as \$\$ begin end \$\$" \
     -c "create event trigger promise_guard_test_audit_evt on ddl_command_end execute function public.evt()" \
     -c "alter event trigger promise_guard_test_audit_evt disable" >/dev/null
check "a disabled event trigger is a breach of the whole database" "disabled_event_trigger|breach" \
    "$(q -c "select kind || '|' || severity from promise_guard.check_promises() where kind = 'disabled_event_trigger'")"

echo "PG-06: a schema that does not exist is not clean"
check "promises_kept() of a missing schema raises" "no schema named" "$(q -c "select promise_guard.promises_kept('nonexistent')")"
check "watch() of a missing schema raises" "no schema named" "$(q -c "select promise_guard.watch('nonexistent')")"
check "control: an existing clean schema is kept" "t" "$(q -c "create schema clean" -c "select promise_guard.promises_kept('clean')" | tail -1)"

echo "PG-07: the check reads the catalog as it is now"
check "under REPEATABLE READ it refuses" "read committed" \
    "$(q -c "begin isolation level repeatable read" -c "select promise_guard.promises_kept('clean')" -c "commit")"

echo "PG-09: an invalid but ready UNIQUE index is enforced for new rows"
q -q -c "create schema cn" -c "create table cn.t (k int)" -c "create unique index cn_k on cn.t (k)" \
     -c "update pg_index set indisvalid = false where indexrelid = 'cn.cn_k'::regclass" >/dev/null
check "control: a duplicate is refused" "duplicate key" "$(q -c "insert into cn.t values (1)" -c "insert into cn.t values (1)")"
check "it is a gap, and says new rows are checked" "unique_index_not_valid|gap" "$(findings cn)"
q -q -c "update pg_index set indisready = false where indexrelid = 'cn.cn_k'::regclass" >/dev/null
check "control: invalid and not ready, it is a breach" "invalid_unique_index|breach" "$(findings cn)"

echo "PG-10: RLS not forced on a table whose owner cannot log in"
q -q -c "create schema rl" -c "create table rl.t (x int)" -c "alter table rl.t enable row level security" -c "alter table rl.t owner to $OWNER" >/dev/null
check "it is a gap, not a breach" "unenforced_rls|gap" "$(findings rl)"
q -q -c "create schema rl2" -c "create table rl2.t (x int)" -c "alter table rl2.t enable row level security" >/dev/null
check "control: owned by a role that can log in, it is a breach" "unenforced_rls|breach" "$(findings rl2)"

echo "PG-11: watch() is idempotent"
first=$(q -c "select promise_guard.watch('clean')")
second=$(q -c "select promise_guard.watch('clean')")
check "a second watch() of the same schema returns the same assertion" "same=yes" "same=$([ -n "$first" ] && [ "$first" = "$second" ] && echo yes || echo "no ($first / $second)")"

if [ "$failures" -ne 0 ]; then
    echo "$failures check(s) failed"
    exit 1
fi
echo "the findings of the 0.2.5 audit are closed, each against its control"
