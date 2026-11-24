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
backup_path ?= /srv/$(stack_name)/backups
backup_label ?=
smoke_path ?= /
migrations_dir ?= migrations
migrations_namespace ?= DoctrineMigrations

define nl


endef

worker_name = $(firstword $(subst :, ,$(1)))
worker_replicas = $(or $(word 2,$(subst :, ,$(1))),1)

require_tag = $(if $(TAG),,$(error TAG is required, e.g. TAG=v1.2.0))
require_postgres = $(if $(filter postgres,$(db_kind)),,$(error db_kind '$(db_kind)' is not supported, only postgres is))

deploy.prod:
	$(MAKE) db.backup
	$(MAKE) docker.deploy.prod
	$(MAKE) deploy.assert_image
	$(foreach w,$(worker_services),$(MAKE) deploy.assert_image assert_service=$(call worker_name,$(w)) assert_image=$(worker_image_name)$(nl))
	castor barlito:castor:wait-db-container
	$(MAKE) doctrine.migrate
	$(MAKE) smoke.test
	$(MAKE) deploy.prune

deploy.update:
	$(MAKE) db.backup
	$(MAKE) deploy.workers.drain
	$(MAKE) docker.service.update args="--image $(image_name):$(TAG) $(stack_name)_$(main_service)"
	$(MAKE) deploy.assert_image
	castor barlito:castor:wait-php-container
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
	$(MAKE) db.backup backup_label=pre-rollback-
	$(MAKE) deploy.workers.drain
	$(MAKE) rollback.database
	$(MAKE) docker.service.update args="--image $(image_name):$(TAG) $(stack_name)_$(main_service)"
	$(MAKE) deploy.assert_image
	$(MAKE) deploy.workers.update
	$(MAKE) smoke.test
	$(MAKE) deploy.prune

rollback.check:
	$(require_tag)
	castor barlito:castor:migrations-rollback-target $(TAG) --dir=$(migrations_dir) --namespace=$(migrations_namespace)

rollback.database:
	$(if $(filter-out 0 false,$(RESTORE)),$(MAKE) db.restore dump=$(RESTORE),$(MAKE) rollback.migrations)

# Runs in the current (newer) php container: it holds the down() code of the migrations to revert
rollback.migrations:
	@out="$$(mktemp)"; trap 'rm -f "$$out"' EXIT; \
	castor barlito:castor:migrations-rollback-target $(TAG) --dir=$(migrations_dir) --namespace=$(migrations_namespace) --output="$$out" || exit 1; \
	version="$$(cat "$$out")"; \
	if [ -z "$$version" ]; then \
		echo "No migration to revert"; \
	else \
		docker exec -t $(app_container_id) bin/console doctrine:migrations:migrate "$$version" --no-interaction; \
	fi

# Custom format (-F c) dump in the host volume $(backup_path), mounted on /backups in the db container; skipped when the DB is not running (first deploy)
db.backup:
	$(require_postgres)
	@cid="$$(docker ps --filter name='$(stack_name)_$(db_service)' -q | head -1)"; \
	if [ -n "$$cid" ]; then \
		ts="$$(date +%Y%m%d-%H%M%S)"; \
		echo "DB backup -> $(backup_path)/$(stack_name)-$(backup_label)$$ts.dump (container $$cid)"; \
		docker exec -t "$$cid" sh -c "pg_dump -U $(db_user) -F c -d $(db_name) -f /backups/$(stack_name)-$(backup_label)$$ts.dump"; \
	else \
		echo "DB container not found, backup skipped (first deploy?)"; \
	fi

# dump=<file name in $(backup_path)>, or 1/latest for the newest deploy backup (pre-rollback backups are ignored)
db.restore:
	$(require_postgres)
	@cid="$$(docker ps --filter name='$(stack_name)_$(db_service)' -q | head -1)"; \
	[ -n "$$cid" ] || { echo "DB container not found, cannot restore"; exit 1; }; \
	dump="$(dump)"; \
	case "$$dump" in \
		1|true|latest) dump="$$(docker exec "$$cid" sh -c 'ls -1t /backups/$(stack_name)-[0-9]*.dump 2>/dev/null | head -1' | xargs -r basename)";; \
		*/*) echo "dump must be a file name, not a path"; exit 1;; \
	esac; \
	[ -n "$$dump" ] || { echo "No dump to restore in $(backup_path)"; exit 1; }; \
	echo "DB restore <- $(backup_path)/$$dump (container $$cid)"; \
	docker exec -t "$$cid" sh -c "pg_restore -U $(db_user) -d $(db_name) --clean --if-exists --no-owner /backups/$$dump"

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
	@curl -fsS -o /dev/null -w "  HTTP %{http_code}\n" https://$(prod_host)$(smoke_path) || (echo "Smoke test FAILED" && exit 1)
	@echo "Smoke test OK"
