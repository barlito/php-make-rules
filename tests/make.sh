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
  ps) case "$*" in *_php*) echo "$FAKE_APP_CID" ;; *) echo "$FAKE_CID" ;; esac ;;
  service) echo "$FAKE_IMAGE" ;;
  exec) case "$*" in
    *"ls -1t"*) echo "$FAKE_LATEST" ;;
    *"test -f"*) [ -z "$FAKE_MISSING" ] ;;
    *doctrine_migration_versions*) [ -z "$FAKE_NOTABLE" ] && printf '%s\n' "$FAKE_APPLIED" ;;
  esac ;;
esac
SHIM
cat > "$work/bin/castor" <<'SHIM'
#!/bin/sh
echo "castor log noise on stdout"
for arg in "$@"; do case "$arg" in --output=*) printf '%s' "$FAKE_VERSION" > "${arg#--output=}" ;; esac; done
SHIM
cat > "$work/bin/curl" <<'SHIM'
#!/bin/sh
echo "curl $*" >> "$FAKE_CURL_LOG"
n=$(cat "$FAKE_CURL_COUNT" 2>/dev/null || echo 0); echo $((n + 1)) > "$FAKE_CURL_COUNT"
[ "$n" -ge "${FAKE_CURL_FAILS:-0}" ]
SHIM
printf '#!/bin/sh\n' > "$work/bin/sleep"
chmod +x "$work/bin/docker" "$work/bin/castor" "$work/bin/curl" "$work/bin/sleep"
export FAKE_CURL_LOG="$work/curl.log" FAKE_CURL_COUNT="$work/curl.count"
# the *_ALL_* logs are never truncated: the final "stack rm" check reads them
export PATH="$work/bin:$PATH" FAKE_DOCKER_LOG="$work/docker.log" FAKE_DOCKER_ALL_LOG="$work/docker.all.log" ALL_OUT="$work/out.all.log"
: > "$ALL_OUT"
unset TAG RESTORE
export FAKE_APP_CID=APPCID

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
    "timeout 300 docker stack deploy --detach=false --with-registry-auth -c docker-compose-prod.yml -c " \
    "castor barlito:castor:assert-deployed carapp_php barlito/carapp:v1.2.0 --timeout=180 --settle=10" \
    "castor barlito:castor:wait-db-container --service=db --php-service=php --stack=carapp" \
    "doctrine:migrations:migrate --no-interaction --allow-no-migration" \
    "docker service scale carapp_message_worker=1" \
    "castor barlito:castor:assert-deployed carapp_message_worker barlito/carapp-worker:v1.2.0 --timeout=180 --settle=10" \
    "curl -fsS --connect-timeout 10 --max-time 30 -o /dev/null -w \"  HTTP %{http_code}\\n\" https://carapp.barlito.fr/" \
    "docker container prune -f --filter label=com.docker.stack.namespace=carapp"
  has "deploy.prod pulls the prod compose" "docker compose -f docker-compose-prod.yml pull"
  hasnt "deploy.prod never removes the stack" "stack rm"
  has "workers are deployed at 0 replicas" "printf '  %s:\\n    deploy:\\n      replicas: 0\\n' message_worker"
  has "recover state armed before the stack deploy" "echo unsafe > \"/tmp/carapp-recover-state\""
  order "recover state armed then cleared once migrated" "echo unsafe >" "doctrine:migrations:migrate" "rm -f \"/tmp/carapp-recover-state\"" "docker service scale carapp_message_worker=1"
  hasnt "prod deploy no longer uses curl --retry" "--retry"
}

check "deploy.update defaults" carapp 0 -n deploy.update && {
  order "deploy.update sequence" \
    "pg_dump -U carapp" \
    "docker service scale carapp_message_worker=0" \
    "docker service update --with-registry-auth --image barlito/carapp:v1.2.0 carapp_php" \
    "castor barlito:castor:assert-deployed carapp_php barlito/carapp:v1.2.0" \
    "castor barlito:castor:wait-php-container --service=php --stack=carapp" \
    "doctrine:migrations:migrate" \
    "docker service update --with-registry-auth --image barlito/carapp-worker:v1.2.0 carapp_message_worker" \
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
    "echo unsafe >" \
    "doctrine:migrations:execute --down \"\$version\" --no-interaction" \
    "echo \"v1.2.0\" >" \
    "docker service update --with-registry-auth --image barlito/carapp:v1.2.0 carapp_php" \
    "castor barlito:castor:assert-deployed carapp_php barlito/carapp:v1.2.0" \
    "docker service update --with-registry-auth --image barlito/carapp-worker:v1.2.0 carapp_message_worker" \
    "docker service scale carapp_message_worker=1" \
    "https://carapp.barlito.fr/" \
    "docker container prune -f"
  hasnt "rollback without RESTORE does not restore" "pg_restore"
  hasnt "rollback never removes the stack" "stack rm"
}

check "rollback RESTORE=1" carapp 0 -n rollback RESTORE=1 && {
  order "RESTORE resolves the dump before the rollback backup" "Will restore" "pg_dump -U carapp" "db.restore dump_file=/tmp/carapp-rollback-restore"
  has "RESTORE restores in one transaction" "psql -U carapp -d carapp -v ON_ERROR_STOP=1 --single-transaction -f -"
  has "rollback backup is labelled" "db.backup backup_label=rollback"
  has "RESTORE=1 targets the version being restored" "carapp-v1.2.0-[0-9]"
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
  has "overridden stack deploy" "timeout 60 docker stack deploy --detach=false --with-registry-auth -c compose.prod.yml ytcg"
  has "overridden assert" "castor barlito:castor:assert-deployed ytcg_app barlito/youl-tcg:v1.2.0 --timeout=30 --settle=2"
  has "overridden backup" "docker ps --filter label=com.docker.swarm.service.name=ytcg_pg -q"
  has "overridden wait-db" "castor barlito:castor:wait-db-container --service=pg --php-service=app --stack=ytcg"
  has "overridden main service inspected" "docker service inspect --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' ytcg_app"
  has "overridden backup user" "pg_dump -U postgres -F c -d ytcg_db -f /backups/\$prefix-\$ts.dump"
  has "overridden smoke path" "https://carapp.barlito.fr/login"
  hasnt "no worker assert without workers" "message_worker"
}
check "deploy.update without workers" custom 0 -n deploy.update && {
  hasnt "no worker scale without workers" "docker service scale"
  has "main service update" "docker service update --with-registry-auth --image barlito/youl-tcg:v1.2.0 ytcg_app"
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

check "no workers: plain stack deploy" custom 0 -n deploy.prod && {
  hasnt "no override without workers" "replicas: 0"
  hasnt "no worker start without workers" "docker service scale"
}
check "deploy.prod migrates through the exact-label lookup" carapp 0 -n deploy.prod && {
  has "app lookup by exact label" "acid=\"\$(docker ps -q --filter label=com.docker.swarm.service.name=carapp_php | head -n1)\""
  hasnt "no app_container_id in prod" "app_container_id"
}
check "deploy.migrate main_service" carapp 0 -n deploy.migrate main_service=web && has "migrate uses main_service" "service.name=carapp_web"
FAKE_APP_CID="" check "deploy.migrate without app" carapp fail deploy.migrate && has "migrate without app explained" "cannot migrate"
FAKE_APP_CID=$'a1\na2' check "deploy.migrate several replicas" carapp 0 deploy.migrate && grep -qE 'exec -t (APPCID|a1|a2) bin/console doctrine:migrations:migrate' "$work/docker.log" && pass "migrate runs in one container" || fail "migrate"

# --- recover: workers go back on the rollback tag, or stay drained
rstate="$work/recover-state"
rm -f "$rstate"
check "recover without state scales up" carapp 0 -n deploy.recover recover_state="$rstate" && has "plain scale up" "docker service scale carapp_message_worker=1"
echo unsafe > "$rstate"
check "recover with unsafe state" carapp fail -n deploy.recover recover_state="$rstate" && {
  has "unsafe state is loud" "ERROR: workers stay drained"
  hasnt "unsafe state scales nothing" "docker service scale carapp_message_worker=1"
}
echo v1.1.0 > "$rstate"
check "recover after the database step" carapp 0 -n deploy.recover recover_state="$rstate" && {
  order "workers updated to the rollback tag before scaling up" "docker service update --with-registry-auth --image barlito/carapp-worker:v1.1.0 carapp_message_worker" "docker service scale carapp_message_worker=1"
}
echo 'v1;x' > "$rstate"
check "recover with a corrupt state" carapp fail -n deploy.recover recover_state="$rstate" && has "corrupt state refused" "unreadable"
rm -f "$rstate"
check "recover unsafe without workers" custom 0 -n deploy.recover && hasnt "nothing to recover" "docker service"

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
FAKE_CID=abc check "db.backup runs" carapp 0 db.backup && has "backup announces file" "DB backup -> /srv/carapp/backups/carapp_unversioned-"
grep -q 'exec -t abc sh -c pg_dump -U carapp -F c -d carapp -f /backups/carapp_unversioned-' "$work/docker.log" && pass "pg_dump executed" || fail "pg_dump not executed: $(cat "$work/docker.log")"
grep -q 'ps --filter label=com.docker.swarm.service.name=carapp_db -q' "$work/docker.log" && pass "container found by exact service label" || fail "label filter not used: $(cat "$work/docker.log")"
grep -q 'filter name=' "$work/docker.log" && fail "name filter used" || pass "no substring name filter"

: > "$work/docker.log"
FAKE_CID=abc FAKE_LATEST=/backups/carapp-20260101-120000.dump check "db.restore latest" carapp 0 db.restore dump=1 && has "restores latest" "carapp-20260101-120000.dump"
grep -qF 'exec -i abc sh -c ' "$work/docker.log" && grep -qF 'pg_restore -f "$f" --no-owner "/backups/$1"' "$work/docker.log" && pass "dump converted to SQL without --single-transaction" || fail "pg_restore step: $(cat "$work/docker.log")"
grep -qF 'psql -U carapp -d carapp -v ON_ERROR_STOP=1 --single-transaction -f -' "$work/docker.log" && pass "reset and restore in one psql transaction" || fail "no single transaction: $(cat "$work/docker.log")"
grep -q 'sh carapp-20260101-120000.dump DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public AUTHORIZATION carapp;' "$work/docker.log" && pass "schema reset passed to the transaction" || fail "schema reset missing: $(cat "$work/docker.log")"
grep -q 'pg_restore -U' "$work/docker.log" && fail "pg_restore writes straight to the db" || pass "pg_restore never commits on its own"
grep -q 'psql.*-c ' "$work/docker.log" && fail "separate committed psql call" || pass "no separate committed reset"
: > "$work/docker.log"
FAKE_CID=abc check "db.restore several schemas" carapp 0 db.restore dump=x.dump db_schemas="public audit" && grep -q 'DROP SCHEMA IF EXISTS public CASCADE; DROP SCHEMA IF EXISTS audit CASCADE; CREATE SCHEMA public AUTHORIZATION carapp;$' "$work/docker.log" && pass "every schema dropped, only public recreated (pg_dump creates the others)" || fail "schemas: $(cat "$work/docker.log")"
: > "$work/docker.log"
FAKE_CID=abc check "db.restore named dump" carapp 0 db.restore dump=carapp-x.dump && grep -q '/backups/carapp-x.dump' "$work/docker.log" && pass "named dump restored" || fail "named dump"
FAKE_CID=abc FAKE_MISSING=1 check "db.restore missing dump" carapp fail db.restore dump=carapp-x.dump && has "missing dump explained" "not found in"
: > "$work/docker.log"
FAKE_CID=abc FAKE_MISSING=1 check "failed restore resets nothing" carapp fail db.restore dump=carapp-x.dump
grep -q 'exec -i' "$work/docker.log" && fail "schema dropped although the dump is missing" || pass "no schema reset when the dump is missing"
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

# --- dump naming: <stack>-<running version>-<ts>, or a name rollback never selects
: > "$work/docker.log"
FAKE_CID=abc FAKE_IMAGE='barlito/carapp:v1.1.0@sha256:0123abcd' check "db.backup versioned" carapp 0 db.backup && has "backup named after the running version" "DB backup -> /srv/carapp/backups/carapp-v1.1.0-"
grep -q 'service inspect' "$work/docker.log" && pass "running version read from the main service" || fail "service not inspected"
FAKE_CID=abc FAKE_IMAGE='barlito/carapp:v1.1.0' check "db.backup versioned without digest" carapp 0 db.backup && has "tag without digest" "carapp-v1.1.0-"
FAKE_CID=abc FAKE_IMAGE='barlito/carapp' check "db.backup untagged image" carapp 0 db.backup && has "untagged image is unversioned" "carapp_unversioned-"
FAKE_CID=abc FAKE_IMAGE='' check "db.backup without service" carapp 0 db.backup && has "unknown version is unversioned" "carapp_unversioned-"
FAKE_CID=abc FAKE_IMAGE='registry:5000/carapp' check "db.backup registry port without tag" carapp 0 db.backup && has "registry port is not a version" "carapp_unversioned-"
FAKE_CID=abc FAKE_IMAGE='barlito/carapp:v1;$(id)' check "db.backup unsafe tag" carapp 0 db.backup && has "unsafe tag is unversioned" "carapp_unversioned-"
FAKE_CID=abc FAKE_IMAGE='barlito/carapp:v1.1.0' check "db.backup labelled" carapp 0 db.backup backup_label=rollback && has "labelled backup ignores the version" "carapp_rollback-"
FAKE_CID="" FAKE_IMAGE='x:v1' check "db.backup optional without db and image" carapp 0 db.backup backup_optional=1 && has "optional backup still skipped" "backup skipped"

# the rollback glob picks only dumps of the target version, never rollback, unversioned or longer-tag dumps
: > "$work/docker.log"
FAKE_CID=abc FAKE_LATEST=/backups/x RESTORE=1 check "rollback.resolve glob" carapp 0 rollback.resolve TAG=v1.2.0 rollback_state="$work/state"
glob="$(grep -o 'ls -1t /backups/[^ ]*' "$work/docker.log" | head -1 | sed 's#ls -1t /backups/##; s#"$##')"
mkdir "$work/dumps"
for f in carapp-v1.2.0-20260101-120000 carapp-v1.2.0-20260102-120000 carapp-v1.2.1-20260109-120000 carapp-v1.2.0-2-20260110-120000 carapp_rollback-20260111-120000 carapp_unversioned-20260112-120000 carapp-v1.2.0-20260113-120000.dump.tmp; do : > "$work/dumps/$f.dump"; done
touch -d '2026-01-01' "$work/dumps/carapp-v1.2.0-20260101-120000.dump"; touch -d '2026-01-02' "$work/dumps/carapp-v1.2.0-20260102-120000.dump"
picked="$(cd "$work/dumps" && ls -1t $glob | head -1)"
[ "$picked" = "carapp-v1.2.0-20260102-120000.dump" ] && pass "newest dump of the target version selected" || fail "picked '$picked' with glob $glob"
[ "$(cd "$work/dumps" && ls -1 $glob | wc -l)" = 2 ] && pass "other versions and safety backups never match" || fail "glob too wide: $glob"
# failed first rollback then retry: the pre-rollback backup is named carapp_rollback-*, so the retry cannot pick it
: > "$work/dumps/carapp_rollback-20260120-120000.dump"
[ "$(cd "$work/dumps" && ls -1t $glob | head -1)" = "carapp-v1.2.0-20260102-120000.dump" ] && pass "retry ignores the earlier pre-rollback backup" || fail "retry picked a safety backup"
FAKE_CID=abc RESTORE=1 TAG='v1;x' check "rollback.resolve unsafe TAG" carapp fail rollback.resolve rollback_state="$work/state" && has "unsafe TAG refused" "not allowed in a dump name"
FAKE_CID=abc FAKE_LATEST="" RESTORE=1 check "rollback.resolve no dump for the version" carapp fail rollback.resolve rollback_state="$work/state" && has "missing version dump explained" "No dump to restore"
FAKE_CID=abc RESTORE=my.dump TAG='v1;x' check "rollback.resolve named dump ignores TAG" carapp 0 rollback.resolve rollback_state="$work/state"

# --- backup retention: the newest backup_keep dumps of the prefix just written survive
: > "$work/docker.log"
FAKE_CID=abc FAKE_IMAGE='barlito/carapp:v1.1.0' check "db.backup retention default" carapp 0 db.backup
grep -qF 'ls -1 /backups/carapp-v1.1.0-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].dump' "$work/docker.log" && grep -qF 'tail -n +11 | xargs -r rm -f --' "$work/docker.log" && pass "keeps 10 per versioned prefix by default" || fail "retention: $(cat "$work/docker.log")"
: > "$work/docker.log"
FAKE_CID=abc check "db.backup retention rollback prefix" carapp 0 db.backup backup_label=rollback backup_keep=3
grep -qF '/backups/carapp_rollback-[0-9]' "$work/docker.log" && grep -qF 'tail -n +4 ' "$work/docker.log" && pass "retention scoped to the rollback prefix" || fail "rollback retention: $(cat "$work/docker.log")"
: > "$work/docker.log"
FAKE_CID=abc check "db.backup retention unversioned prefix" carapp 0 db.backup && grep -qF '/backups/carapp_unversioned-[0-9]' "$work/docker.log" && pass "retention scoped to the unversioned prefix" || fail "unversioned retention"
: > "$work/docker.log"
FAKE_CID=abc check "db.backup retention disabled" carapp 0 db.backup backup_keep=0
grep -q 'pg_dump' "$work/docker.log" && ! grep -q 'xargs' "$work/docker.log" && pass "backup_keep=0 keeps every dump" || fail "retention not disabled"
: > "$work/docker.log"
FAKE_CID=abc check "db.backup invalid retention" carapp fail db.backup backup_keep=ten && has "invalid retention explained" "backup_keep must be a number"
grep -q 'pg_dump' "$work/docker.log" && fail "backup ran with an invalid backup_keep" || pass "invalid backup_keep stops before the dump"

# the retention one-liner against real files: newest by name, other prefixes untouched
mkdir "$work/ret"
for f in carapp-v1-20260101-000001 carapp-v1-20260101-000002 carapp-v1-20260101-000003 carapp-v1-20260101-000004 carapp_rollback-20260101-000001 carapp-v1-2-20260101-000001; do : > "$work/ret/$f.dump"; done
(cd "$work/ret" && ls -1 carapp-v1-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].dump | sort -r | tail -n +3 | xargs -r rm -f --)
[ "$(ls "$work/ret" | tr '\n' ' ')" = "carapp-v1-2-20260101-000001.dump carapp-v1-20260101-000003.dump carapp-v1-20260101-000004.dump carapp_rollback-20260101-000001.dump " ] && pass "retention drops only the oldest of its own prefix" || fail "retention result: $(ls "$work/ret")"

# --- smoke test retries the whole request
: > "$FAKE_CURL_LOG"; echo 0 > "$FAKE_CURL_COUNT"
FAKE_CURL_FAILS=2 check "smoke succeeds after failures" carapp 0 smoke.test smoke_retries=3 smoke_delay=0 && has "smoke retried" "attempt 2/3 failed"
[ "$(grep -c "^curl" "$FAKE_CURL_LOG")" = 3 ] && pass "curl called until it answered" || fail "curl calls: $(cat "$FAKE_CURL_LOG")"
echo 0 > "$FAKE_CURL_COUNT"
FAKE_CURL_FAILS=99 check "smoke gives up" carapp fail smoke.test smoke_retries=3 smoke_delay=0 && has "smoke failure reported" "Smoke test FAILED"
[ "$(cat "$FAKE_CURL_COUNT")" = 3 ] && pass "exactly smoke_retries attempts" || fail "attempts: $(cat "$FAKE_CURL_COUNT")"
echo 0 > "$FAKE_CURL_COUNT"
check "smoke first try" carapp 0 smoke.test && [ "$(cat "$FAKE_CURL_COUNT")" = 1 ] && pass "no retry when the app answers" || fail "smoke first try"

# --- castor missing: fail before any side effect
mkdir "$work/nocastor"
cp "$work/bin/docker" "$work/nocastor/docker"
for target in deploy.prod deploy.update rollback; do
  : > "$work/docker.log"
  out="$(cd "$work/carapp" && PATH="$work/nocastor:/usr/bin:/bin" make --no-print-directory $target 2>&1)"; status=$?
  printf '%s\n' "$out" >> "$ALL_OUT"
  if [ "$status" -ne 0 ]; then pass "$target without castor fails"; else fail "$target without castor succeeded"; fi
  has "$target without castor explains" "castor not found in PATH"
  [ -s "$work/docker.log" ] && fail "$target ran docker before checking castor: $(cat "$work/docker.log")" || pass "$target without castor has no side effect"
done
for target in deploy.prod deploy.update rollback; do
  check "$target checks castor right after TAG" carapp 0 -n $target
  [ "$(printf '%s\n' "$out" | head -1)" = 'command -v castor >/dev/null 2>&1 || { echo "castor not found in PATH: install it before running this target (nothing was changed)"; exit 1; }' ] && pass "$target: castor check comes first" || fail "$target: castor check not first"
done

# --- rollback.migrations reverts only the recorded migrations, newest first
: > "$work/docker.log"
V1='DoctrineMigrations\Version1'; V2='DoctrineMigrations\Version2'
FAKE_CID=abc FAKE_APPLIED="$V1"$'\n'"$V2" FAKE_VERSION="$V2"$'\n'"$V1"$'\n' check "rollback.migrations reverts" carapp 0 rollback.migrations TAG=v1 && hasnt "revert ignores castor noise" "No migration to revert"
[ "$(grep -c 'migrations:execute --down' "$work/docker.log")" = 2 ] && pass "one execute per recorded migration" || fail "executes: $(cat "$work/docker.log")"
[ "$(grep -n 'Version2 --no' "$work/docker.log" | cut -d: -f1)" -lt "$(grep -n 'Version1 --no' "$work/docker.log" | cut -d: -f1)" ] && pass "newest reverted first" || fail "revert order"
grep -qF 'exec -t APPCID bin/console doctrine:migrations:execute --down DoctrineMigrations\Version2 --no-interaction' "$work/docker.log" && pass "execute --down used" || fail "execute: $(cat "$work/docker.log")"
FAKE_CID=abc FAKE_APP_CID=$'a1\na2' check "rollback.migrations several replicas" carapp 0 rollback.migrations TAG=v1
grep -q 'ps -q --filter label=com.docker.swarm.service.name=carapp_php' "$work/docker.log" && pass "app container found by exact service label" || fail "app lookup: $(cat "$work/docker.log")"
FAKE_CID=abc FAKE_APP_CID="" FAKE_APPLIED="$V1" FAKE_VERSION="$V1"$'\n' check "rollback.migrations without app container" carapp fail rollback.migrations TAG=v1 && has "no app container explained" "not found, cannot revert"
FAKE_CID=abc FAKE_APPLIED="$V1" FAKE_VERSION="$V1"$'\n' check "rollback.migrations main_service" carapp 0 rollback.migrations TAG=v1 main_service=web && grep -q 'service.name=carapp_web' "$work/docker.log" && pass "main_service used for the app lookup" || fail "main_service ignored"
grep -q 'psql -U carapp -d carapp -tA -c SELECT version FROM doctrine_migration_versions' "$work/docker.log" && pass "applied versions read from the db" || fail "no applied query: $(cat "$work/docker.log")"

: > "$work/docker.log"
FAKE_CID=abc FAKE_APPLIED="$V1" FAKE_VERSION="$V2"$'\n'"$V1"$'\n' check "rollback.migrations skips unapplied" carapp 0 rollback.migrations TAG=v1 && has "unapplied announced" "Skipping $V2: not applied"
[ "$(grep -c 'migrations:execute --down' "$work/docker.log")" = 1 ] && grep -q 'execute --down DoctrineMigrations\\Version1 ' "$work/docker.log" && pass "only the recorded migration reverted" || fail "unapplied reverted: $(cat "$work/docker.log")"

: > "$work/docker.log"
FAKE_CID=abc FAKE_NOTABLE=1 FAKE_VERSION="$V1"$'\n' check "rollback.migrations without versions table" carapp fail rollback.migrations TAG=v1 && has "missing table explained" "doctrine_migration_versions (table missing?)"
grep -q 'migrations:execute' "$work/docker.log" && fail "reverted without the versions table" || pass "nothing reverted without the versions table"
FAKE_CID="" FAKE_VERSION="$V1"$'\n' check "rollback.migrations without db container" carapp fail rollback.migrations TAG=v1 && has "no db explained" "DB container not found"
check "rollback.migrations db_kind" mysql fail rollback.migrations TAG=v1 && has "db_kind explained" "not supported"

: > "$work/docker.log"
FAKE_VERSION='' check "rollback.migrations without revert" carapp 0 rollback.migrations TAG=v1 && has "nothing to revert" "No migration to revert"
[ -s "$work/docker.log" ] && fail "docker called without migration to revert" || pass "no docker call without migration to revert"

# cumulative logs, never truncated
grep -q 'stack rm' "$work/docker.all.log" "$ALL_OUT" && fail "stack rm found in a log" || pass "stack rm never issued"

if [ "$failures" -gt 0 ]; then echo "$failures failure(s)"; exit 1; fi
echo "all make tests passed"
