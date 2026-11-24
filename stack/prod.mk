### Production rules
# Set in the project Makefile: stack_name, prod_host, image_name (and worker_image_name when there are workers)

main_service ?= php
# Space-separated "service:replicas" (replicas default to 1), e.g. "message_worker:2 mailer"
worker_services ?= $(if $(worker_image_name),message_worker:1)
worker_image_name ?=
prod_compose_file ?= docker-compose-prod.yml
deploy_timeout ?= 300
assert_timeout ?= 180
assert_settle ?= 10
assert_service ?= $(main_service)
assert_image ?= $(image_name)
db_kind ?= postgres
db_service ?= db
db_user ?= $(stack_name)
db_name ?= $(stack_name)
db_schemas ?= public
backup_path ?= /srv/$(stack_name)/backups
backup_optional ?=
rollback_state ?= /tmp/$(stack_name)-rollback-restore
smoke_path ?= /
migrations_dir ?= migrations
migrations_namespace ?= DoctrineMigrations

define nl


endef

worker_name = $(firstword $(subst :, ,$(1)))
worker_replicas = $(or $(word 2,$(subst :, ,$(1))),1)

require_tag = $(if $(TAG),,$(error TAG is required, e.g. TAG=v1.2.0))
require_postgres = $(if $(filter postgres,$(db_kind)),,$(error db_kind '$(db_kind)' is not supported, only postgres is))

# Exact match on the swarm service label: a name filter would match substrings
db_cid = cid="$$(docker ps --filter label=com.docker.swarm.service.name=$(stack_name)_$(db_service) -q | head -1)"

# Resolves $$dump (1|true|latest, or a file name) against $(backup_path); needs $$cid and $$dump
find_dump = case "$$dump" in \
	1|true|latest) dump="$$(docker exec "$$cid" sh -c 'ls -1t /backups/$(stack_name)-[0-9]*.dump 2>/dev/null | head -1' | xargs -r basename)";; \
	*/*) echo "dump must be a file name, not a path"; exit 1;; \
esac; \
[ -n "$$dump" ] || { echo "No dump to restore in $(backup_path)"; exit 1; }; \
docker exec "$$cid" test -f "/backups/$$dump" || { echo "Dump $$dump not found in $(backup_path)"; exit 1; }

deploy.prod:
	$(require_tag)
	$(MAKE) db.backup backup_optional=1
	$(MAKE) docker.deploy.prod
	$(MAKE) deploy.assert_image
	$(foreach w,$(worker_services),$(MAKE) deploy.assert_image assert_service=$(call worker_name,$(w)) assert_image=$(worker_image_name)$(nl))
	castor barlito:castor:wait-db-container --service=$(db_service) --php-service=$(main_service)
	$(MAKE) doctrine.migrate
	$(MAKE) smoke.test
	$(MAKE) deploy.prune

deploy.update:
	$(require_tag)
	$(MAKE) db.backup
	$(MAKE) deploy.workers.drain
	$(MAKE) docker.service.update args="--image $(image_name):$(TAG) $(stack_name)_$(main_service)"
	$(MAKE) deploy.assert_image
	castor barlito:castor:wait-php-container --service=$(main_service)
	$(MAKE) doctrine.migrate
	$(MAKE) deploy.workers.update
	$(MAKE) smoke.test
	$(MAKE) deploy.prune

# Never leave the workers scaled down after a failed deploy
deploy.recover:
	$(MAKE) deploy.workers.scale_up

deploy.workers.drain:
	$(foreach w,$(worker_services),docker service scale $(stack_name)_$(call worker_name,$(w))=0$(nl))

deploy.workers.scale_up:
	$(foreach w,$(worker_services),docker service scale $(stack_name)_$(call worker_name,$(w))=$(call worker_replicas,$(w))$(nl))

deploy.workers.update:
	$(foreach w,$(worker_services),$(MAKE) deploy.worker.update worker=$(w)$(nl))

deploy.worker.update:
	$(MAKE) docker.service.update args="--image $(worker_image_name):$(TAG) $(stack_name)_$(call worker_name,$(worker))"
	docker service scale $(stack_name)_$(call worker_name,$(worker))=$(call worker_replicas,$(worker))
	$(MAKE) deploy.assert_image assert_service=$(call worker_name,$(worker)) assert_image=$(worker_image_name)

# TAG=<tag> required; RESTORE=1|<dump file> restores the DB instead of reverting migrations
rollback:
	$(require_tag)
	$(MAKE) rollback.check
	$(MAKE) rollback.resolve
	$(MAKE) db.backup
	$(MAKE) deploy.workers.drain
	$(MAKE) rollback.database
	$(MAKE) docker.service.update args="--image $(image_name):$(TAG) $(stack_name)_$(main_service)"
	$(MAKE) deploy.assert_image
	$(MAKE) deploy.workers.update
	$(MAKE) smoke.test
	$(MAKE) deploy.prune
	@rm -f "$(rollback_state)"

rollback.check:
	$(require_tag)
	castor barlito:castor:migrations-rollback-target $(TAG) --dir=$(migrations_dir) --namespace=$(migrations_namespace)

# Picks the dump before the rollback backup exists, so the backup can never be selected
rollback.resolve:
	@rm -f "$(rollback_state)"; \
	case "$(RESTORE)" in ""|0|false) exit 0;; esac; \
	$(db_cid); \
	[ -n "$$cid" ] || { echo "DB container not found, cannot restore"; exit 1; }; \
	dump="$(RESTORE)"; \
	$(find_dump); \
	echo "$$dump" > "$(rollback_state)"; \
	echo "Will restore $$dump"

rollback.database:
	$(if $(filter-out 0 false,$(RESTORE)),$(MAKE) db.restore dump_file=$(rollback_state),$(MAKE) rollback.migrations)

# Runs in the current (newer) php container, which holds the down() code; reverts exactly the added migrations, newest first
rollback.migrations:
	@out="$$(mktemp)"; trap 'rm -f "$$out"' EXIT; \
	castor barlito:castor:migrations-rollback-target $(TAG) --dir=$(migrations_dir) --namespace=$(migrations_namespace) --output="$$out" || exit 1; \
	if [ ! -s "$$out" ]; then \
		echo "No migration to revert"; \
	else \
		while IFS= read -r version || [ -n "$$version" ]; do \
			docker exec -t $(app_container_id) bin/console doctrine:migrations:execute --down "$$version" --no-interaction || exit 1; \
		done < "$$out"; \
	fi

# Custom format (-F c) dump in the host volume $(backup_path), mounted on /backups in the db container; only deploy.prod may skip it (first deploy)
db.backup:
	$(require_postgres)
	@$(db_cid); \
	if [ -n "$$cid" ]; then \
		ts="$$(date +%Y%m%d-%H%M%S)"; \
		echo "DB backup -> $(backup_path)/$(stack_name)-$$ts.dump (container $$cid)"; \
		docker exec -t "$$cid" sh -c "pg_dump -U $(db_user) -F c -d $(db_name) -f /backups/$(stack_name)-$$ts.dump"; \
	elif [ -n "$(backup_optional)" ]; then \
		echo "DB container not found, backup skipped (first deploy?)"; \
	else \
		echo "DB container $(stack_name)_$(db_service) not found: refusing to continue without a backup"; \
		exit 1; \
	fi

# dump=<file name in $(backup_path)>, or 1/latest for the newest deploy backup; dump_file=<path> reads the name from a file
db.restore:
	$(require_postgres)
	@$(db_cid); \
	[ -n "$$cid" ] || { echo "DB container not found, cannot restore"; exit 1; }; \
	dump="$(dump)"; \
	[ -z "$(dump_file)" ] || dump="$$(cat "$(dump_file)")"; \
	$(find_dump); \
	echo "DB restore <- $(backup_path)/$$dump (container $$cid)"; \
	docker exec -t "$$cid" psql -U $(db_user) -d $(db_name) -v ON_ERROR_STOP=1 -c "$(foreach s,$(db_schemas),DROP SCHEMA IF EXISTS $(s) CASCADE; CREATE SCHEMA $(s) AUTHORIZATION $(db_user);)" \
	&& docker exec -t "$$cid" pg_restore -U $(db_user) -d $(db_name) --single-transaction --no-owner "/backups/$$dump"

# Swarm rollbacks exit 0: fail unless the service really runs the tag, healthy (castor task)
deploy.assert_image:
	$(require_tag)
	$(if $(assert_image),,$(error image_name is required))
	castor barlito:castor:assert-deployed $(stack_name)_$(assert_service) $(assert_image):$(TAG) --timeout=$(assert_timeout) --settle=$(assert_settle)

# Removes the stack's stopped containers (old tasks); prune never touches running ones
deploy.prune:
	docker container prune -f --filter label=com.docker.stack.namespace=$(stack_name)

# Fails on 4xx/5xx; a redirect to a login page proves the app answers
smoke.test:
	@echo "Smoke test https://$(prod_host)$(smoke_path)"
	@curl -fsS --connect-timeout 10 --max-time 30 --retry 2 --retry-delay 3 -o /dev/null -w "  HTTP %{http_code}\n" https://$(prod_host)$(smoke_path) || (echo "Smoke test FAILED" && exit 1)
	@echo "Smoke test OK"
