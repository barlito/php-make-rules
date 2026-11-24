#!/usr/bin/env bash
# Runs inside the php container: migrations-rollback-target against throwaway git repositories
set -uo pipefail

work="$(mktemp -d)"
failures=0

fail() { echo "FAIL: $1"; failures=$((failures + 1)); }
pass() { echo "ok:   $1"; }

new_repo() { # new_repo <name>
  repo="$work/$1"
  mkdir -p "$repo"
  cd "$repo" || exit 1
  git init -q
  git config user.email test@example.com
  git config user.name test
  ln -s /repo make
  printf '<?php\nuse function Castor\\import;\ndefined("CASTOR_USE_CHDIR") || define("CASTOR_USE_CHDIR", true);\nimport("make/castor_entrypoint.php");\n' > castor.php
}

migration() { # migration <dir> <version>
  mkdir -p "$1"
  echo '<?php' > "$1/Version$2.php"
}

commit_tag() { # commit_tag <tag>
  git add -A -- . ':!make' ':!castor.php'
  git -c commit.gpgsign=false commit -q --allow-empty -m "$1"
  git tag "$1"
}

target() { castor barlito:castor:migrations-rollback-target "$@" --output="$work/version" 2>"$work/stderr" && cat "$work/version"; }

expect() { # expect <description> <expected stdout> <task args...>
  local desc="$1" expected="$2"; shift 2
  local got
  got="$(target "$@")"
  if [ "$got" = "$expected" ]; then pass "$desc"; else fail "$desc: expected '$expected', got '$got' ($(cat "$work/stderr"))"; fi
}

N='DoctrineMigrations\Version'

new_repo crossing
migration migrations 20240101000000
migration migrations 20240201000000
commit_tag v1
migration migrations 20240301000000
migration migrations 20240401000000
commit_tag v2
expect "reverts exactly the added migrations, newest first" "${N}20240401000000"$'\n'"${N}20240301000000" v1
grep -q 'Migrations added since v1: .*Version20240301000000' "$work/stderr" && pass "lists added migrations on stderr" || fail "added migrations not reported"
expect "nothing to revert when the tag has every migration" '' v2
expect "custom namespace" 'App\Migrations\Version20240401000000'$'\n''App\Migrations\Version20240301000000' v1 --namespace='App\Migrations'

new_repo olderAdded
migration migrations 20240101000000
migration migrations 20240301000000
commit_tag v1
migration migrations 20240201000000
commit_tag v2
expect "an added migration older than the tag's last one is reverted alone" "${N}20240201000000" v1

new_repo squashed
migration migrations 20240101000000
migration migrations 20240201000000
commit_tag v1
git rm -q migrations/Version20240101000000.php
migration migrations 20240301000000
commit_tag v2
expect "a migration missing from the tree is ignored" "${N}20240301000000" v1

new_repo noMigrationsInTag
echo init > README
commit_tag v1
migration migrations 20240101000000
migration migrations 20240201000000
commit_tag v2
expect "reverts everything when the tag has no migration" "${N}20240201000000"$'\n'"${N}20240101000000" v1

new_repo noMigrationsAtAll
echo init > README
commit_tag v1
commit_tag v2
expect "nothing to revert without migrations" '' v1

new_repo customDir
migration db/migrations 20240101000000
commit_tag v1
migration db/migrations 20240201000000
commit_tag v2
expect "custom migrations directory" 'DoctrineMigrations\Version20240201000000' v1 --dir=db/migrations
expect "default directory ignores other directories" '' v1

new_repo unknownTag
migration migrations 20240101000000
commit_tag v1
if target v9 >/dev/null; then fail "unknown tag must fail"; else grep -q 'fetch' "$work/stderr" && pass "unknown tag fails with a hint" || fail "unknown tag message: $(cat "$work/stderr")"; fi

# wait tasks: Swarm label first, compose labels second, exact name last (docker shimmed, it only answers `ps` and `inspect`)
mkdir "$work/shim"
cat > "$work/shim/docker" <<'SHIM'
#!/bin/sh
echo "$*" >> "$FAKE_DOCKER_LOG"
case "$1" in
  ps) case "$*" in
    *com.docker.swarm.service.name=*) printf '%s' "$FAKE_SWARM" ;;
    *com.docker.compose.service=*) printf '%s' "$FAKE_COMPOSE" ;;
    *name=*) printf '%s' "$FAKE_NAME" ;;
  esac ;;
  inspect) echo none ;;
  exec) exit 0 ;;
esac
SHIM
chmod +x "$work/shim/docker"
export FAKE_DOCKER_LOG="$work/docker.log"
wait_php() { : > "$FAKE_DOCKER_LOG"; PATH="$work/shim:$PATH" castor barlito:castor:wait-php-container "$@" >"$work/wait.out" 2>&1; }

new_repo waits
FAKE_SWARM=swarmid FAKE_COMPOSE="" FAKE_NAME="" wait_php --stack=ytcg && grep -q 'inspect.*swarmid' "$FAKE_DOCKER_LOG" && pass "Swarm service found by label" || fail "swarm lookup: $(cat "$work/wait.out")"
grep -q 'label=com.docker.compose' "$FAKE_DOCKER_LOG" && fail "compose lookup although a Swarm task matched" || pass "compose lookup skipped when Swarm matches"
FAKE_SWARM="" FAKE_COMPOSE=composeid FAKE_NAME="" wait_php --stack=ytcg && grep -q 'inspect.*composeid' "$FAKE_DOCKER_LOG" && pass "compose service found" || fail "compose lookup: $(cat "$work/wait.out")"
grep -qF 'label=com.docker.compose.project=ytcg' "$FAKE_DOCKER_LOG" && grep -qF 'label=com.docker.compose.service=php' "$FAKE_DOCKER_LOG" && pass "compose lookup scoped to the project and the service" || fail "compose filters: $(cat "$FAKE_DOCKER_LOG")"
FAKE_SWARM="" FAKE_COMPOSE="" FAKE_NAME=nameid wait_php --stack=ytcg && grep -qF 'name=^/ytcg_php$' "$FAKE_DOCKER_LOG" && pass "exact container name fallback" || fail "name lookup: $(cat "$work/wait.out")"
new_repo waitsenv
printf '<?php\nuse Castor\\Attribute\\AsContext;\nuse Castor\\Context;\nuse function Castor\\import;\ndefined("CASTOR_USE_CHDIR") || define("CASTOR_USE_CHDIR", true);\nimport("make/castor_entrypoint.php");\n#[AsContext(default: true)]\nfunction ctx(): Context { return new Context(environment: ["STACK_NAME" => "envstack"]); }\n' > castor.php
FAKE_SWARM="" FAKE_COMPOSE=composeid FAKE_NAME="" wait_php && grep -qF 'compose.project=envstack' "$FAKE_DOCKER_LOG" && pass "STACK_NAME of the context still used without --stack" || fail "STACK_NAME default: $(cat "$work/wait.out")"
FAKE_SWARM="" FAKE_COMPOSE=composeid FAKE_NAME="" wait_php --stack=ytcg && grep -qF 'compose.project=ytcg' "$FAKE_DOCKER_LOG" && pass "--stack wins over the context" || fail "--stack: $(cat "$work/wait.out")"
FAKE_SWARM="" FAKE_COMPOSE=composeid FAKE_NAME="" wait_php --stack=ytcg --service=web && grep -qF 'compose.service=web' "$FAKE_DOCKER_LOG" && pass "--service honoured" || fail "service option"
: > "$FAKE_DOCKER_LOG"
FAKE_SWARM=dbid PATH="$work/shim:$PATH" castor barlito:castor:wait-db-container --stack=ytcg --service=db --php-service=php >"$work/wait.out" 2>&1 && pass "wait-db-container takes --stack" || fail "wait-db: $(cat "$work/wait.out")"

castor barlito:castor:wait-db-container --help 2>/dev/null | grep -q -- '--php-service' && pass "wait-db-container takes service names" || fail "wait-db-container options"
castor barlito:castor:wait-php-container --help 2>/dev/null | grep -q -- '--service' && pass "wait-php-container takes a service name" || fail "wait-php-container options"

if [ "$failures" -gt 0 ]; then echo "$failures failure(s)"; exit 1; fi
echo "all castor tests passed"
