#!/usr/bin/env bash
# Round trip of db.backup / db.restore against a real Postgres container
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
image="postgres@sha256:f9cf3e1f0066f0eb0c48707d864f0ac5941e9ff454a072077d97a4d278d07d73"
name="pgtest-db-$$"
cleanup() { docker rm -f "$name" >/dev/null 2>&1; rm -rf "$work"; }
trap cleanup EXIT

failures=0
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }
pass() { echo "ok:   $1"; }

ln -s "$root" "$work/make"
printf 'stack_name=pgtest\ndb_user=app\ndb_name=app\nprod_host=localhost\nimage_name=x/y\ninclude make/entrypoint.mk\n' > "$work/Makefile"

docker run -d --name "$name" --label com.docker.swarm.service.name=pgtest_db \
  -e POSTGRES_USER=app -e POSTGRES_PASSWORD=app -e POSTGRES_DB=app "$image" >/dev/null || exit 1
docker exec -u root "$name" sh -c 'mkdir -p /backups && chown postgres /backups'

for _ in $(seq 1 60); do
  docker exec "$name" pg_isready -U app -d app >/dev/null 2>&1 && break
  sleep 1
done
sleep 2

sql() { docker exec "$name" psql -U app -d app -tA -c "$1"; }
mk() { (cd "$work" && make --no-print-directory "$@"); }
rows() { sql 'SELECT string_agg(v, $$,$$ ORDER BY id) FROM t'; }

sql "CREATE TABLE t (id int PRIMARY KEY, v text); INSERT INTO t VALUES (1, 'original')" >/dev/null

mk db.backup >/dev/null || fail "db.backup failed"
dump="$(docker exec "$name" sh -c 'ls -1t /backups/pgtest[-_]*.dump | head -1' | xargs -r basename)"
[ -n "$dump" ] && pass "backup written: $dump" || fail "no dump written"

sql "UPDATE t SET v = 'mutated'; INSERT INTO t VALUES (2, 'extra'); CREATE TABLE junk (a int)" >/dev/null
mk db.restore dump=1 >/dev/null || fail "db.restore failed"
[ "$(rows)" = "original" ] && pass "restore brings the original rows back" || fail "rows after restore: $(rows)"
[ "$(sql "SELECT to_regclass('junk')")" = "" ] && pass "objects created after the backup are gone" || fail "junk table survived the restore"

sql "UPDATE t SET v = 'precious'" >/dev/null
docker exec "$name" sh -c "head -c 200 /backups/$dump > /backups/pgtest-corrupt-20260101-000000.dump"
mk db.restore dump=pgtest-corrupt-20260101-000000.dump >/dev/null 2>&1 && fail "corrupt dump restored without error" || pass "corrupt dump is refused"
[ "$(rows)" = "precious" ] && pass "failed restore leaves the data intact" || fail "data after failed restore: $(rows)"

# SQL that fails after the schema reset has run: the reset must be rolled back with it
mk db.restore dump="$dump" db_schemas="public 1bad" >/dev/null 2>&1 && fail "broken restore SQL reported success" || pass "restore failing midway is reported"
[ "$(rows)" = "precious" ] && pass "failed transaction keeps the previous schema" || fail "data after midway failure: $(rows)"

# A dump holding a non-public schema: pg_dump emits CREATE SCHEMA for it, so the reset must only drop it
sql "UPDATE t SET v = 'original'; CREATE SCHEMA audit; CREATE TABLE audit.log (id int, msg text); INSERT INTO audit.log VALUES (1, 'kept')" >/dev/null
mk db.backup >/dev/null || fail "db.backup with a second schema failed"
audit_dump="$(docker exec "$name" sh -c 'ls -1t /backups/pgtest_unversioned-*.dump | head -1' | xargs -r basename)"
sql "UPDATE t SET v = 'mutated'; INSERT INTO audit.log VALUES (2, 'extra'); CREATE TABLE audit.junk (a int); CREATE TABLE pubjunk (a int)" >/dev/null
mk db.restore dump="$audit_dump" db_schemas="public audit" >/dev/null 2>"$work/err" && pass "restore of a dump with a non-public schema" || fail "restore with schema audit: $(cat "$work/err")"
[ "$(rows)" = "original" ] && pass "public rows restored" || fail "public rows: $(rows)"
[ "$(sql 'SELECT string_agg(msg, $$,$$) FROM audit.log')" = "kept" ] && pass "audit schema restored" || fail "audit rows: $(sql 'SELECT string_agg(msg, $$,$$) FROM audit.log' 2>&1)"
[ "$(sql "SELECT to_regclass('audit.junk')")" = "" ] && [ "$(sql "SELECT to_regclass('pubjunk')")" = "" ] && pass "objects created after the backup are gone from both schemas" || fail "junk survived in a schema"

# Retention: only the newest backup_keep dumps of the prefix stay
for _ in 1 2 3; do sleep 1; mk db.backup backup_keep=2 >/dev/null || fail "db.backup with retention failed"; done
count="$(docker exec "$name" sh -c 'ls -1 /backups/pgtest_unversioned-*.dump | wc -l')"
[ "$count" = 2 ] && pass "backup_keep=2 leaves the 2 newest dumps" || fail "dumps left: $count"
docker exec "$name" sh -c 'touch /backups/pgtest_rollback-20200101-000000.dump /backups/pgtest-v1-20200101-000000.dump'
sleep 1; mk db.backup backup_keep=1 >/dev/null
docker exec "$name" sh -c 'ls /backups/pgtest_rollback-20200101-000000.dump /backups/pgtest-v1-20200101-000000.dump' >/dev/null 2>&1 && pass "other prefixes are never pruned" || fail "retention touched another prefix"
sleep 1; mk db.backup backup_keep=0 >/dev/null; sleep 1; mk db.backup backup_keep=0 >/dev/null
[ "$(docker exec "$name" sh -c 'ls -1 /backups/pgtest_unversioned-*.dump | wc -l')" -ge 3 ] && pass "backup_keep=0 disables retention" || fail "backup_keep=0 pruned"

if [ "$failures" -gt 0 ]; then echo "$failures failure(s)"; exit 1; fi
echo "all postgres tests passed"
