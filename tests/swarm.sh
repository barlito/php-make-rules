#!/usr/bin/env bash
# End-to-end run of deploy.prod, deploy.update, rollback and deploy.recover on a real single-node Swarm.
# The app is a fake: busybox images, a bin/console that records its calls and a real Postgres service.
# CI only (fresh runner). Locally it needs an active swarm and refuses to share it unless SWARM_TEST_SHARED=1.
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
stack=swtest
compose_project=swcomp
registry_name=swtest-registry
port="${SWARM_TEST_REGISTRY_PORT:-5055}"
busybox="busybox@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec"
registry_image="registry@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373"
postgres_image="postgres@sha256:f9cf3e1f0066f0eb0c48707d864f0ac5941e9ff454a072077d97a4d278d07d73"
castor_sha="3312568da9a593ad7d3ef6548f05c12d994dbc7140634e401531dc8d7de41764"

export REG="localhost:$port" CALLS="$work/calls" BACKUPS="$work/backups" DB_IMAGE="$postgres_image" BUSYBOX="$busybox"
app="$work/app"
initialised_swarm=""

failures=0
fail() { echo "FAIL: $1"; failures=$((failures + 1)); }
pass() { echo "ok:   $1"; }
check() { if "${@:2}"; then pass "$1"; else fail "$1"; fi; }

cleanup() {
  cd /
  docker compose -p "$compose_project" -f "$work/compose-ci.yml" down -t 1 >/dev/null 2>&1
  docker stack rm "$stack" >/dev/null 2>&1
  for _ in $(seq 1 30); do
    [ -z "$(docker ps -aq --filter "label=com.docker.stack.namespace=$stack")" ] && break
    sleep 1
  done
  docker volume rm $(docker volume ls -q --filter "label=com.docker.stack.namespace=$stack") >/dev/null 2>&1
  docker rm -f "$registry_name" >/dev/null 2>&1
  [ -z "$initialised_swarm" ] || docker swarm leave --force >/dev/null 2>&1
  rm -rf "$work"
}
trap cleanup EXIT

if [ "$(docker info --format '{{.Swarm.LocalNodeState}}')" = active ]; then
  others="$(docker service ls --format '{{.Name}}' | grep -v "^${stack}_" | head -1)"
  if [ -n "$others" ] && [ -z "${SWARM_TEST_SHARED:-}" ]; then
    echo "This swarm already runs other services ($others): set SWARM_TEST_SHARED=1 to deploy the $stack test stack next to them"
    exit 2
  fi
else
  timeout 60 docker swarm init --advertise-addr 127.0.0.1 >/dev/null || exit 1
  initialised_swarm=1
fi

castor_bin="$(command -v castor || true)"
if [ -z "$castor_bin" ]; then
  mkdir "$work/castor-bin"
  curl -fsSL --max-time 120 -o "$work/castor-bin/castor" https://github.com/jolicode/castor/releases/download/v1.9.1/castor.linux-amd64.phar || exit 1
  echo "$castor_sha  $work/castor-bin/castor" | sha256sum -c - >/dev/null || exit 1
  chmod +x "$work/castor-bin/castor"
  export PATH="$work/castor-bin:$PATH"
fi

mkdir -p "$CALLS" "$BACKUPS" "$app/ctx/app/bin" "$app/ctx/app/php"
chmod 777 "$CALLS" "$BACKUPS"

# --- registry and fake app images
timeout 120 docker run -d --name "$registry_name" -p "127.0.0.1:$port:5000" "$registry_image" >/dev/null || exit 1
for _ in $(seq 1 30); do curl -fsS --max-time 2 -o /dev/null "http://$REG/v2/" && break; sleep 1; done

cat > "$app/ctx/app/bin/console" <<'EOF'
#!/bin/sh
echo "$(cut -d' ' -f1 /proc/uptime) $*" >> /calls/console.log
EOF
cat > "$app/ctx/app/php/php" <<'EOF'
#!/bin/sh
nc -w 2 db 5432 </dev/null
EOF
cat > "$app/ctx/Dockerfile" <<'EOF'
ARG BUSYBOX
FROM ${BUSYBOX}
ARG VERSION
ARG HEALTHY=1
COPY app/bin /app/bin
COPY app/php/php /usr/local/bin/php
RUN chmod +x /app/bin/console /usr/local/bin/php && mkdir -p /www && echo "$VERSION" > /www/index.html \
 && if [ "$HEALTHY" = 1 ]; then touch /www/ok; fi
WORKDIR /app
HEALTHCHECK --interval=2s --timeout=3s --retries=1 --start-period=1s CMD test -f /www/ok && wget -q -O /dev/null http://127.0.0.1:8080/
CMD ["httpd", "-f", "-p", "8080", "-h", "/www"]
EOF
build() { # build <tag> <healthy 1|0>
  timeout 120 docker build -q -t "$REG/fakeapp:$1" --build-arg "BUSYBOX=$BUSYBOX" --build-arg "VERSION=$1" --build-arg "HEALTHY=$2" "$app/ctx" >/dev/null \
    && docker tag "$REG/fakeapp:$1" "$REG/fakeapp-worker:$1" \
    && timeout 120 docker push -q "$REG/fakeapp:$1" >/dev/null && timeout 120 docker push -q "$REG/fakeapp-worker:$1" >/dev/null
}
for t in v1 v2; do build "$t" 1 || { echo "cannot build $t"; exit 1; }; done
build bad 0 || { echo "cannot build bad"; exit 1; }

# --- the project: compose file, Makefile, castor.php, git history
cat > "$app/docker-compose-prod.yml" <<'EOF'
services:
  php:
    image: ${REG}/fakeapp:${TAG}
    volumes:
      - ${CALLS}:/calls
  message_worker:
    image: ${REG}/fakeapp-worker:${TAG}
    command: ["sh", "-c", "cut -d' ' -f1 /proc/uptime >> /calls/worker.log; while :; do sleep 1; done"]
    healthcheck:
      disable: true
    volumes:
      - ${CALLS}:/calls
    deploy:
      replicas: 1
  db:
    image: ${DB_IMAGE}
    environment:
      POSTGRES_USER: app
      POSTGRES_PASSWORD: app
      POSTGRES_DB: app
    healthcheck:
      test: ["CMD", "pg_isready", "-U", "app", "-d", "app"]
      interval: 2s
      retries: 30
    volumes:
      - ${BACKUPS}:/backups
EOF
cat > "$work/compose-ci.yml" <<'EOF'
services:
  php:
    image: ${REG}/fakeapp:v1
    container_name: swcomp_php
  db:
    image: ${REG}/fakeapp:v1
    container_name: swcomp_db
    command: ["httpd", "-f", "-p", "5432", "-h", "/www"]
    healthcheck:
      disable: true
EOF
cat > "$app/Makefile" <<'EOF'
stack_name=swtest
prod_host=localhost
image_name=$(REG)/fakeapp
worker_image_name=$(REG)/fakeapp-worker
db_user=app
db_name=app
backup_path=$(BACKUPS)
deploy_timeout=180
assert_timeout=90
assert_settle=3
include make/entrypoint.mk

# The Swarm ingress does not answer on CI runners: ask the task itself
smoke.test:
	@cid="$$(docker ps -q --filter label=com.docker.swarm.service.name=swtest_php | head -n1)"; \
	timeout 20 docker exec "$$cid" wget -q -T 5 -O - http://127.0.0.1:8080/ | grep -qx "$(TAG)"
EOF
printf '<?php\ndefined("CASTOR_USE_CHDIR") || define("CASTOR_USE_CHDIR", true);\nCastor\\import("make/castor_entrypoint.php");\n' > "$app/castor.php"
ln -s "$root" "$app/make"
(
  cd "$app" || exit 1
  git init -q && git config user.email t@example.com && git config user.name t && git config commit.gpgsign false
  printf '*\n!migrations/\n!migrations/*\n!.gitignore\n' > .gitignore
  mkdir migrations && echo '<?php' > migrations/Version1.php
  git add -A && git commit -q -m v1 && git tag v1
  echo '<?php' > migrations/Version2.php
  git add -A && git commit -q -m v2 && git tag v2
) || exit 1

mk() { local t="$1"; shift; (cd "$app" && timeout "$t" make --no-print-directory "$@"); }
sql() { docker exec "$(docker ps -q --filter "label=com.docker.swarm.service.name=${stack}_db" | head -n1)" psql -U app -d app -tA -c "$1"; }
service_image() { docker service inspect --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' "${stack}_$1" 2>/dev/null | sed 's/@.*//'; }
running() { docker service ps "${stack}_$1" --filter desired-state=running --format '{{.CurrentState}}' 2>/dev/null | grep -c '^Running'; }
last_field() { tail -n1 "$1" | cut -d' ' -f1; }
later() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }
console_calls() { grep -c "$1" "$CALLS/console.log" 2>/dev/null || true; }
state() { # state <expected main image tag> <expected worker count>
  [ "$(service_image php)" = "$REG/fakeapp:$1" ] && [ "$(service_image message_worker)" = "$REG/fakeapp-worker:$1" ] && [ "$(running php)" = 1 ] && [ "$(running message_worker)" = "$2" ]
}

# --- first deploy: the stack does not exist yet
export TAG=v1
mk 600 deploy.prod TAG=v1 && pass "deploy.prod on a first deploy" || fail "deploy.prod v1"
check "stack runs v1, workers up" state v1 1
check "migrations ran through the app container" test "$(console_calls 'doctrine:migrations:migrate')" -ge 1
if [ -s "$CALLS/worker.log" ]; then
  later "$(last_field "$CALLS/worker.log")" "$(last_field "$CALLS/console.log")" && pass "workers started after the migrations" || fail "workers started before the migrations"
else fail "no worker start recorded"; fi

sql 'CREATE TABLE t (id int PRIMARY KEY, v text); INSERT INTO t VALUES (1, $$at-v1$$); CREATE TABLE doctrine_migration_versions (version varchar(191) PRIMARY KEY); INSERT INTO doctrine_migration_versions VALUES ($$DoctrineMigrations\Version1$$)' >/dev/null

# --- rolling update
mk 600 deploy.update TAG=v2 && pass "deploy.update" || fail "deploy.update v2"
check "stack runs v2, workers up" state v2 1
ls "$BACKUPS"/swtest-v1-*.dump >/dev/null 2>&1 && pass "update backup named after the running version" || fail "no swtest-v1 dump"
sql 'INSERT INTO doctrine_migration_versions VALUES ($$DoctrineMigrations\Version2$$)' >/dev/null

# --- full deploy on an existing stack: workers must wait for the migrations
starts_before="$(wc -l < "$CALLS/worker.log")"
mk 600 deploy.prod TAG=v2 && pass "deploy.prod on an existing stack" || fail "deploy.prod v2"
check "stack still runs v2, workers up" state v2 1
[ "$(wc -l < "$CALLS/worker.log")" -gt "$starts_before" ] && later "$(last_field "$CALLS/worker.log")" "$(last_field "$CALLS/console.log")" && pass "workers restarted only after the migrations" || fail "workers not restarted after the migrations"

# --- rollback by reverting migrations
downs_before="$(console_calls 'migrations:execute --down')"
mk 600 rollback TAG=v1 && pass "rollback" || fail "rollback v1"
check "stack back on v1, workers up" state v1 1
grep -qF 'migrations:execute --down DoctrineMigrations\Version2' "$CALLS/console.log" && pass "the added migration was reverted" || fail "no revert of Version2"
[ "$(console_calls 'migrations:execute --down')" -gt "$downs_before" ] && ! grep -qF 'execute --down DoctrineMigrations\Version1' "$CALLS/console.log" && pass "only the migrations added since v1 were reverted" || fail "unexpected revert"
ls "$BACKUPS"/swtest_rollback-*.dump >/dev/null 2>&1 && pass "rollback safety backup written" || fail "no rollback backup"
sql 'DELETE FROM doctrine_migration_versions WHERE version LIKE $$%Version2$$' >/dev/null

# --- rollback by restoring the dump taken while v1 was running
sql 'UPDATE t SET v = $$state-of-v1$$' >/dev/null
sleep 1
mk 600 deploy.update TAG=v2 || fail "deploy.update v2 again"
sql 'UPDATE t SET v = $$mutated-by-v2$$' >/dev/null
downs_before="$(console_calls 'migrations:execute --down')"
mk 600 rollback TAG=v1 RESTORE=1 && pass "rollback RESTORE=1" || fail "rollback RESTORE=1"
check "stack back on v1 after the restore" state v1 1
[ "$(sql 'SELECT v FROM t')" = "state-of-v1" ] && pass "database restored from the v1 dump" || fail "table t holds: $(sql 'SELECT v FROM t')"
[ "$(console_calls 'migrations:execute --down')" = "$downs_before" ] && pass "no migration reverted when restoring" || fail "migrations reverted during a restore"

# --- forced healthcheck failure: assert-deployed fails the deploy, recover brings the workers back
mk 400 deploy.update TAG=bad >"$work/bad.out" 2>&1 && fail "deploy.update of an unhealthy image succeeded" || pass "deploy.update of an unhealthy image fails"
(cd "$app" && timeout 120 castor barlito:castor:assert-deployed "${stack}_php" "$REG/fakeapp:bad" --timeout=20 --settle=2 >"$work/assert.out" 2>&1) && fail "assert-deployed accepted an unhealthy image" || pass "assert-deployed fails on the unhealthy image"
[ "$(running message_worker)" = 0 ] && pass "workers are still drained after the failed deploy" || fail "workers running after the failed deploy"
mk 120 deploy.recover && pass "deploy.recover" || fail "deploy.recover"
[ "$(running message_worker)" = 1 ] && [ "$(service_image message_worker)" = "$REG/fakeapp-worker:v1" ] && pass "workers back on the previous image" || fail "workers not restored: $(running message_worker) on $(service_image message_worker)"

# --- compose-based CI stack (docker compose up, no Swarm label): the wait tasks must find it
(cd "$app" && TAG=v1 timeout 120 docker compose -p "$compose_project" -f "$work/compose-ci.yml" up -d >/dev/null 2>&1) || fail "docker compose up"
(cd "$app" && timeout 120 castor barlito:castor:wait-php-container --stack="$compose_project" >/dev/null 2>&1) && pass "wait-php-container finds a compose container" || fail "wait-php-container on compose"
(cd "$app" && timeout 180 castor barlito:castor:wait-db-container --stack="$compose_project" >/dev/null 2>&1) && pass "wait-db-container finds compose containers" || fail "wait-db-container on compose"

if [ "$failures" -gt 0 ]; then
  echo "$failures failure(s)"
  tail -n 40 "$work/bad.out" 2>/dev/null
  exit 1
fi
echo "all swarm tests passed"
