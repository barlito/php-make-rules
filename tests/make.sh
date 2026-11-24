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
case "$1" in
  ps) echo "$FAKE_CID" ;;
  exec) case "$*" in *"ls -1t"*) echo "$FAKE_LATEST" ;; esac ;;
esac
SHIM
cat > "$work/bin/castor" <<'SHIM'
#!/bin/sh
echo "castor log noise on stdout"
for arg in "$@"; do case "$arg" in --output=*) printf '%s' "$FAKE_VERSION" > "${arg#--output=}" ;; esac; done
SHIM
chmod +x "$work/bin/docker" "$work/bin/castor"
export PATH="$work/bin:$PATH" FAKE_DOCKER_LOG="$work/docker.log"
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
    "curl -fsS -o /dev/null -w \"  HTTP %{http_code}\\n\" https://carapp.barlito.fr/" \
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
    "-f /backups/carapp-pre-rollback-" \
    "docker service scale carapp_message_worker=0" \
    "doctrine:migrations:migrate \"\$version\" --no-interaction" \
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
  has "RESTORE restores the latest dump" "pg_restore -U carapp -d carapp --clean --if-exists --no-owner"
  hasnt "RESTORE replaces the migration revert" "doctrine:migrations:migrate"
}
check "rollback RESTORE=0 is off" carapp 0 -n rollback RESTORE=0 && has "RESTORE=0 reverts migrations" "doctrine:migrations:migrate"

TAG="" check "rollback without TAG" carapp fail -n rollback && has "rollback without TAG explains" "TAG is required"
TAG="" check "assert_image without TAG" carapp fail -n deploy.assert_image && has "assert_image without TAG explains" "TAG is required"

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
  has "overridden backup" "docker ps --filter name='ytcg_pg' -q"
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

# --- db.backup / db.restore with a fake docker
: > "$work/docker.log"
FAKE_CID="" check "db.backup skipped without db" carapp 0 db.backup && has "backup skipped" "backup skipped"
grep -q pg_dump "$work/docker.log" && fail "backup must not run without db" || pass "no pg_dump without db"
FAKE_CID=abc check "db.backup runs" carapp 0 db.backup backup_label=pre-rollback- && has "backup announces file" "carapp-pre-rollback-"
grep -q 'exec -t abc sh -c pg_dump -U carapp -F c -d carapp -f /backups/carapp-pre-rollback-' "$work/docker.log" && pass "pg_dump executed" || fail "pg_dump not executed: $(cat "$work/docker.log")"

: > "$work/docker.log"
FAKE_CID=abc FAKE_LATEST=/backups/carapp-20260101-120000.dump check "db.restore latest" carapp 0 db.restore dump=1 && has "restores latest" "carapp-20260101-120000.dump"
grep -q 'pg_restore -U carapp -d carapp --clean --if-exists --no-owner /backups/carapp-20260101-120000.dump' "$work/docker.log" && pass "pg_restore executed" || fail "pg_restore not executed: $(cat "$work/docker.log")"
: > "$work/docker.log"
FAKE_CID=abc check "db.restore named dump" carapp 0 db.restore dump=carapp-x.dump && grep -q '/backups/carapp-x.dump' "$work/docker.log" && pass "named dump restored" || fail "named dump"
FAKE_CID=abc FAKE_LATEST="" check "db.restore without dump" carapp fail db.restore dump=latest && has "no dump explained" "No dump to restore"
FAKE_CID=abc check "db.restore path rejected" carapp fail db.restore dump=../etc/x && has "path explained" "not a path"
FAKE_CID="" check "db.restore without db" carapp fail db.restore dump=1 && has "no db explained" "DB container not found"

# --- rollback.migrations reads the version from the castor output file
: > "$work/docker.log"
FAKE_VERSION='DoctrineMigrations\Version2' check "rollback.migrations reverts" carapp 0 rollback.migrations TAG=v1 && hasnt "revert ignores castor noise" "No migration to revert"
grep -qF 'exec -t APPCID bin/console doctrine:migrations:migrate DoctrineMigrations\Version2 --no-interaction' "$work/docker.log" && pass "migrations reverted to the detected version" || fail "revert not executed: $(cat "$work/docker.log")"
: > "$work/docker.log"
FAKE_VERSION='' check "rollback.migrations without revert" carapp 0 rollback.migrations TAG=v1 && has "nothing to revert" "No migration to revert"
[ -s "$work/docker.log" ] && fail "docker called without migration to revert" || pass "no docker call without migration to revert"

grep -q 'stack rm' "$work/docker.log" && fail "stack rm called"

if [ "$failures" -gt 0 ]; then echo "$failures failure(s)"; exit 1; fi
echo "all make tests passed"
