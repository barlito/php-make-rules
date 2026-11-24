#!/usr/bin/env bash
# make -n assertions for the production targets; docker is shimmed so nothing can reach a real daemon
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

mkdir "$work/bin"
cat > "$work/bin/docker" <<'SHIM'
#!/bin/sh
echo "docker $*" >> "$FAKE_DOCKER_LOG"
echo "docker $*" >> "$FAKE_DOCKER_ALL_LOG"
case "$1" in
  ps) echo "$FAKE_CID" ;;
  exec) case "$*" in
    *"ls -1t"*) echo "$FAKE_LATEST" ;;
    *"test -f"*) [ -z "$FAKE_MISSING" ] ;;
  esac ;;
esac
SHIM
cat > "$work/bin/castor" <<'SHIM'
#!/bin/sh
echo "castor log noise on stdout"
for arg in "$@"; do case "$arg" in --output=*) printf '%s' "$FAKE_VERSION" > "${arg#--output=}" ;; esac; done
SHIM
chmod +x "$work/bin/docker" "$work/bin/castor"
# the *_ALL_* logs are never truncated: the final "stack rm" check reads them
export PATH="$work/bin:$PATH" FAKE_DOCKER_LOG="$work/docker.log" FAKE_DOCKER_ALL_LOG="$work/docker.all.log" ALL_OUT="$work/out.all.log"
: > "$ALL_OUT"
unset TAG RESTORE

ln -s "$root" "$work/make"
failures=0

fail() { echo "FAIL: $1"; failures=$((failures + 1)); }
pass() { echo "ok:   $1"; }

# fixture <name> <extra Makefile lines>: carapp-like variables plus extras, before the include
fixture() {
  mkdir -p "$work/$1"
  ln -sfn "$work/make" "$work/$1/make"
  {
    printf 'stack_name=carapp\napp_container_id=APPCID\nprod_host=carapp.barlito.fr\n'
    printf 'image_name=barlito/carapp\nworker_image_name=barlito/carapp-worker\n'
    printf '%s\n' "$2"
    printf 'include make/entrypoint.mk\n'
    printf '%s\n' "${3:-}"
  } > "$work/$1/Makefile"
}

# run_make <fixture> <make args...>: output in $out, status in $status
run_make() {
  local fx="$1"; shift
  out="$(cd "$work/$fx" && make --no-print-directory "$@" 2>&1)"
  status=$?
  printf '%s\n' "$out" >> "$ALL_OUT"
}

contains() { grep -qF -- "$2" <<< "$1"; }

check() { # check <description> <fixture> <expected status 0|fail> <make args...>
  local desc="$1" fx="$2" expect="$3"; shift 3
  run_make "$fx" "$@"
  if [ "$expect" = 0 ] && [ "$status" -ne 0 ]; then fail "$desc (exit $status): $out"; return 1; fi
  if [ "$expect" = fail ] && [ "$status" -eq 0 ]; then fail "$desc (expected failure)"; return 1; fi
  return 0
}

has() { # has <description> <expected substring> (against $out)
  if contains "$out" "$2"; then pass "$1"; else fail "$1: missing '$2' in:
$out"; fi
}

hasnt() {
  if contains "$out" "$2"; then fail "$1: unexpected '$2'"; else pass "$1"; fi
}

order() { # order <description> <pattern...>: patterns appear in this order in $out
  local desc="$1" last=0 n pat; shift
  for pat in "$@"; do
    n="$(grep -nF -- "$pat" <<< "$out" | awk -F: -v last="$last" '$1 > last {print $1; exit}')"
    if [ -z "$n" ]; then fail "$desc: '$pat' not found after line $last in:
$out"; return; fi
    last="$n"
  done
  pass "$desc"
}

# --- carapp-like defaults
fixture carapp ""
export TAG=v1.2.0

check "deploy.prod defaults" carapp 0 -n deploy.prod && {
  order "deploy.prod sequence" \
    "pg_dump -U carapp -F c -d carapp" \
    "timeout 300 docker stack deploy --detach=false -c docker-compose-prod.yml carapp" \
    "castor barlito:castor:assert-deployed carapp_php barlito/carapp:v1.2.0 --timeout=180 --settle=10" \
    "castor barlito:castor:assert-deployed carapp_message_worker barlito/carapp-worker:v1.2.0 --timeout=180 --settle=10" \
    "castor barlito:castor:wait-db-container" \
    "doctrine:migrations:migrate --no-interaction --allow-no-migration" \
    "curl -fsS --connect-timeout 10 --max-time 30 --retry 2 --retry-delay 3 -o /dev/null -w \"  HTTP %{http_code}\\n\" https://carapp.barlito.fr/" \
    "docker container prune -f --filter label=com.docker.stack.namespace=carapp"
  has "deploy.prod pulls the prod compose" "docker compose -f docker-compose-prod.yml pull"
  hasnt "deploy.prod never removes the stack" "stack rm"
}

check "deploy.update defaults" carapp 0 -n deploy.update && {
  order "deploy.update sequence" \
    "pg_dump -U carapp" \
    "docker service scale carapp_message_worker=0" \
    "docker service update --image barlito/carapp:v1.2.0 carapp_php" \
    "castor barlito:castor:assert-deployed carapp_php barlito/carapp:v1.2.0" \
    "castor barlito:castor:wait-php-container" \
    "doctrine:migrations:migrate" \
    "docker service update --image barlito/carapp-worker:v1.2.0 carapp_message_worker" \
    "docker service scale carapp_message_worker=1" \
    "castor barlito:castor:assert-deployed carapp_message_worker barlito/carapp-worker:v1.2.0" \
    "https://carapp.barlito.fr/" \
    "docker container prune -f"
  hasnt "deploy.update never removes the stack" "stack rm"
}

check "deploy.recover defaults" carapp 0 -n deploy.recover && {
  has "recover rescales the worker" "docker service scale carapp_message_worker=1"
  hasnt "recover does not touch the main service" "carapp_php"
}

check "rollback defaults" carapp 0 -n rollback && {
  order "rollback sequence" \
    "castor barlito:castor:migrations-rollback-target v1.2.0 --dir=migrations --namespace=DoctrineMigrations" \
    "Will restore" \
    "pg_dump -U carapp -F c -d carapp" \
    "docker service scale carapp_message_worker=0" \
    "doctrine:migrations:execute --down \"\$version\" --no-interaction" \
    "docker service update --image barlito/carapp:v1.2.0 carapp_php" \
    "castor barlito:castor:assert-deployed carapp_php barlito/carapp:v1.2.0" \
    "docker service update --image barlito/carapp-worker:v1.2.0 carapp_message_worker" \
    "docker service scale carapp_message_worker=1" \
    "https://carapp.barlito.fr/" \
    "docker container prune -f"
  hasnt "rollback without RESTORE does not restore" "pg_restore"
  hasnt "rollback never removes the stack" "stack rm"
}

check "rollback RESTORE=1" carapp 0 -n rollback RESTORE=1 && {
  order "RESTORE resolves the dump before the rollback backup" "Will restore" "pg_dump -U carapp" "db.restore dump_file=/tmp/carapp-rollback-restore"
  has "RESTORE restores in one transaction" "pg_restore -U carapp -d carapp --single-transaction --no-owner"
  hasnt "RESTORE replaces the migration revert" "doctrine:migrations:execute"
}
check "rollback RESTORE=0 is off" carapp 0 -n rollback RESTORE=0 && has "RESTORE=0 reverts migrations" "doctrine:migrations:execute --down"

TAG="" check "rollback without TAG" carapp fail -n rollback && has "rollback without TAG explains" "TAG is required"
TAG="" check "assert_image without TAG" carapp fail -n deploy.assert_image && has "assert_image without TAG explains" "TAG is required"

for target in deploy.prod deploy.update rollback; do
  TAG="" check "$target without TAG" carapp fail -n $target && has "$target without TAG explains" "TAG is required"
  hasnt "$target without TAG runs nothing first" "pg_dump"
done
check "deploy.prod backup is optional only there" carapp 0 -n deploy.prod && has "first deploy may skip the backup" "make db.backup backup_optional=1"
check "deploy.update backup is mandatory" carapp 0 -n deploy.update && hasnt "no optional backup in update" "backup_optional"

# --- no workers, every parameter overridden
fixture custom 'stack_name=ytcg
image_name=barlito/youl-tcg
worker_image_name=
main_service=app
db_user=postgres
db_name=ytcg_db
db_service=pg
backup_path=/data/backups
smoke_path=/login
prod_compose_file=compose.prod.yml
deploy_timeout=60
assert_timeout=30
assert_settle=2
migrations_dir=db/migrations'
check "deploy.prod overridden" custom 0 -n deploy.prod && {
  has "overridden stack deploy" "timeout 60 docker stack deploy --detach=false -c compose.prod.yml ytcg"
  has "overridden assert" "castor barlito:castor:assert-deployed ytcg_app barlito/youl-tcg:v1.2.0 --timeout=30 --settle=2"
  has "overridden backup" "docker ps --filter label=com.docker.swarm.service.name=ytcg_pg -q"
  has "overridden wait-db" "castor barlito:castor:wait-db-container --service=pg --php-service=app"
  has "overridden backup user" "pg_dump -U postgres -F c -d ytcg_db -f /backups/ytcg-\$ts.dump"
  has "overridden smoke path" "https://carapp.barlito.fr/login"
  hasnt "no worker assert without workers" "message_worker"
}
check "deploy.update without workers" custom 0 -n deploy.update && {
  hasnt "no worker scale without workers" "docker service scale"
  has "main service update" "docker service update --image barlito/youl-tcg:v1.2.0 ytcg_app"
}
check "deploy.recover without workers" custom 0 -n deploy.recover && hasnt "recover without workers" "docker service"
check "rollback overridden" custom 0 -n rollback && has "migrations dir forwarded" "--dir=db/migrations"

# --- several workers with replicas
fixture workers 'worker_services=message_worker:2 mailer' 
check "multi workers update" workers 0 -n deploy.update && {
  has "drain first worker" "docker service scale carapp_message_worker=0"
  has "drain second worker" "docker service scale carapp_mailer=0"
  has "scale first worker back to 2" "docker service scale carapp_message_worker=2"
  has "scale second worker back to 1" "docker service scale carapp_mailer=1"
  has "assert second worker" "castor barlito:castor:assert-deployed carapp_mailer barlito/carapp-worker:v1.2.0"
}
check "multi workers recover" workers 0 -n deploy.recover && {
  has "recover first worker" "docker service scale carapp_message_worker=2"
  has "recover second worker" "docker service scale carapp_mailer=1"
}
check "multi workers prod" workers 0 -n deploy.prod && has "assert both workers" "carapp_mailer barlito/carapp-worker:v1.2.0"

# --- assert variables
check "assert override" carapp 0 -n deploy.assert_image assert_service=other assert_image=foo/bar && has "assert override command" "assert-deployed carapp_other foo/bar:v1.2.0"

# --- db_kind
fixture mysql 'db_kind=mysql'
for target in db.backup db.restore deploy.prod deploy.update rollback; do
  check "db_kind mysql $target" mysql fail -n $target
  has "db_kind mysql $target explains" "db_kind 'mysql' is not supported"
done

# --- project overrides win
fixture override "" 'deploy.prod:
	echo custom-deploy'
check "project override" override 0 deploy.prod && has "override wins" "custom-deploy"

# --- db.backup / db.restore / rollback steps with a fake docker
: > "$work/docker.log"
FAKE_CID="" check "db.backup without db is an error" carapp fail db.backup && has "backup refusal explained" "refusing to continue without a backup"
FAKE_CID="" check "db.backup optional without db" carapp 0 db.backup backup_optional=1 && has "backup skipped" "backup skipped"
grep -q pg_dump "$work/docker.log" && fail "backup must not run without db" || pass "no pg_dump without db"
FAKE_CID=abc check "db.backup runs" carapp 0 db.backup && has "backup announces file" "DB backup -> /srv/carapp/backups/carapp-"
grep -q 'exec -t abc sh -c pg_dump -U carapp -F c -d carapp -f /backups/carapp-' "$work/docker.log" && pass "pg_dump executed" || fail "pg_dump not executed: $(cat "$work/docker.log")"
grep -q 'ps --filter label=com.docker.swarm.service.name=carapp_db -q' "$work/docker.log" && pass "container found by exact service label" || fail "label filter not used: $(cat "$work/docker.log")"
grep -q 'filter name=' "$work/docker.log" && fail "name filter used" || pass "no substring name filter"

: > "$work/docker.log"
FAKE_CID=abc FAKE_LATEST=/backups/carapp-20260101-120000.dump check "db.restore latest" carapp 0 db.restore dump=1 && has "restores latest" "carapp-20260101-120000.dump"
grep -q 'exec -t abc psql -U carapp -d carapp -v ON_ERROR_STOP=1 -c DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public AUTHORIZATION carapp;' "$work/docker.log" && pass "schema dropped and recreated" || fail "schema reset missing: $(cat "$work/docker.log")"
grep -q 'pg_restore -U carapp -d carapp --single-transaction --no-owner /backups/carapp-20260101-120000.dump' "$work/docker.log" && pass "pg_restore executed" || fail "pg_restore not executed: $(cat "$work/docker.log")"
[ "$(grep -n 'psql' "$work/docker.log" | cut -d: -f1)" -lt "$(grep -n 'pg_restore' "$work/docker.log" | cut -d: -f1)" ] && pass "schema reset precedes restore" || fail "restore order"
: > "$work/docker.log"
FAKE_CID=abc check "db.restore several schemas" carapp 0 db.restore dump=x.dump db_schemas="public audit" && grep -q 'DROP SCHEMA IF EXISTS audit CASCADE; CREATE SCHEMA audit AUTHORIZATION carapp;' "$work/docker.log" && pass "every schema reset" || fail "schemas: $(cat "$work/docker.log")"
: > "$work/docker.log"
FAKE_CID=abc check "db.restore named dump" carapp 0 db.restore dump=carapp-x.dump && grep -q '/backups/carapp-x.dump' "$work/docker.log" && pass "named dump restored" || fail "named dump"
FAKE_CID=abc FAKE_MISSING=1 check "db.restore missing dump" carapp fail db.restore dump=carapp-x.dump && has "missing dump explained" "not found in"
: > "$work/docker.log"
FAKE_CID=abc FAKE_MISSING=1 check "failed restore resets nothing" carapp fail db.restore dump=carapp-x.dump
grep -q psql "$work/docker.log" && fail "schema dropped although the dump is missing" || pass "no schema reset when the dump is missing"
FAKE_CID=abc FAKE_LATEST="" check "db.restore without dump" carapp fail db.restore dump=latest && has "no dump explained" "No dump to restore"
FAKE_CID=abc check "db.restore path rejected" carapp fail db.restore dump=../etc/x && has "path explained" "not a path"
FAKE_CID="" check "db.restore without db" carapp fail db.restore dump=1 && has "no db explained" "DB container not found"

# --- rollback.resolve picks the dump before the rollback backup exists
state="$work/state"
FAKE_CID=abc FAKE_LATEST=/backups/carapp-20260101-120000.dump RESTORE=1 check "rollback.resolve" carapp 0 rollback.resolve rollback_state="$state" && [ "$(cat "$state")" = "carapp-20260101-120000.dump" ] && pass "resolved dump recorded" || fail "state: $(cat "$state" 2>&1)"
FAKE_CID=abc RESTORE=my.dump check "rollback.resolve named" carapp 0 rollback.resolve rollback_state="$state" && [ "$(cat "$state")" = "my.dump" ] && pass "named dump recorded" || fail "named state"
FAKE_CID=abc RESTORE=0 check "rollback.resolve off" carapp 0 rollback.resolve rollback_state="$state"
[ -e "$state" ] && fail "state left when RESTORE=0" || pass "no state without RESTORE"
FAKE_CID=abc FAKE_MISSING=1 RESTORE=my.dump check "rollback.resolve missing dump" carapp fail rollback.resolve rollback_state="$state" && has "missing dump stops before any change" "not found in"
FAKE_CID="" RESTORE=1 check "rollback.resolve without db" carapp fail rollback.resolve rollback_state="$state"
: > "$work/docker.log"
echo "carapp-20250505-000000.dump" > "$work/restore-name"
FAKE_CID=abc check "db.restore from state file" carapp 0 db.restore dump_file="$work/restore-name" && grep -q '/backups/carapp-20250505-000000.dump' "$work/docker.log" && pass "dump read from the state file" || fail "dump_file: $(cat "$work/docker.log")"

# --- rollback.migrations reverts the listed migrations, newest first
: > "$work/docker.log"
FAKE_VERSION=$'DoctrineMigrations\\Version2\nDoctrineMigrations\\Version1\n' check "rollback.migrations reverts" carapp 0 rollback.migrations TAG=v1 && hasnt "revert ignores castor noise" "No migration to revert"
[ "$(grep -c 'migrations:execute --down' "$work/docker.log")" = 2 ] && pass "one execute per migration" || fail "executes: $(cat "$work/docker.log")"
[ "$(grep -n 'Version2' "$work/docker.log" | cut -d: -f1)" -lt "$(grep -n 'Version1' "$work/docker.log" | cut -d: -f1)" ] && pass "newest reverted first" || fail "revert order"
grep -qF 'exec -t APPCID bin/console doctrine:migrations:execute --down DoctrineMigrations\Version2 --no-interaction' "$work/docker.log" && pass "execute --down used" || fail "execute: $(cat "$work/docker.log")"
: > "$work/docker.log"
FAKE_VERSION='' check "rollback.migrations without revert" carapp 0 rollback.migrations TAG=v1 && has "nothing to revert" "No migration to revert"
[ -s "$work/docker.log" ] && fail "docker called without migration to revert" || pass "no docker call without migration to revert"

# cumulative logs, never truncated
grep -q 'stack rm' "$work/docker.all.log" "$ALL_OUT" && fail "stack rm found in a log" || pass "stack rm never issued"

if [ "$failures" -gt 0 ]; then echo "$failures failure(s)"; exit 1; fi
echo "all make tests passed"
