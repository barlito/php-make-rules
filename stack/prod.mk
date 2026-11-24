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
# Newest dumps kept per name prefix after a successful backup; 0 keeps every dump
backup_keep ?= 10
backup_label ?=
rollback_state ?= /tmp/$(stack_name)-rollback-restore
# Written when the workers must not be restarted blindly: "unsafe", or the tag the workers must run
recover_state ?= /tmp/$(stack_name)-recover-state
# Extra compose file merged after prod_compose_file by docker.deploy.prod
prod_compose_override ?=
smoke_path ?= /
smoke_retries ?= 12
smoke_delay ?= 10
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

require_castor = command -v castor >/dev/null 2>&1 || { echo "castor not found in PATH: install it before running this target (nothing was changed)"; exit 1; }

ts_glob = [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]

# Running version = tag of the main service image; empty when unknown or not a file-name-safe tag
running_version = img="$$(docker service inspect --format '{{.Spec.TaskTemplate.ContainerSpec.Image}}' $(stack_name)_$(main_service) 2>/dev/null)"; \
	img="$${img%%@*}"; version=""; \
	case "$$img" in *:*) version="$${img\#\#*:}";; esac; \
	case "$$version" in *[!A-Za-z0-9._-]*) version="";; esac

# Local lookup by exact service label: several replicas give several IDs
app_cid = acid="$$(docker ps -q --filter label=com.docker.swarm.service.name=$(stack_name)_$(main_service) | head -n1)"

# Runs in the db container: $$1 dump name, $$2 schema reset SQL; a corrupt dump aborts before anything is dropped
restore_script = f=$$(mktemp) || exit 1; \
	if pg_restore -f "$$f" --no-owner "/backups/$$1"; then \
		{ printf "%s\n" "$$2"; cat "$$f"; } | psql -U $(db_user) -d $(db_name) -v ON_ERROR_STOP=1 --single-transaction -f -; rc=$$?; \
	else rc=1; fi; \
	rm -f "$$f"; exit $$rc

# pg_dump recreates every non-public schema itself but never public: drop them all, recreate only public
reset_sql = $(foreach s,$(db_schemas),DROP SCHEMA IF EXISTS $(s) CASCADE;) $(if $(filter public,$(db_schemas)),CREATE SCHEMA public AUTHORIZATION $(db_user);)

# Resolves $$dump (1|true|latest, or a file name) against $(backup_path); needs $$cid, $$dump and $$glob (file pattern used for latest)
find_dump = case "$$dump" in \
	1|true|latest) dump="$$(docker exec "$$cid" sh -c "ls -1t /backups/$$glob 2>/dev/null | head -1" | xargs -r basename)";; \
	*/*) echo "dump must be a file name, not a path"; exit 1;; \
esac; \
[ -n "$$dump" ] || { echo "No dump to restore in $(backup_path) (pattern $$glob)"; exit 1; }; \
docker exec "$$cid" test -f "/backups/$$dump" || { echo "Dump $$dump not found in $(backup_path)"; exit 1; }

deploy.prod:
	$(require_tag)
	@$(require_castor)
	@rm -f "$(recover_state)"
	$(MAKE) db.backup backup_optional=1
	@echo unsafe > "$(recover_state)"
	$(MAKE) deploy.stack
	$(MAKE) deploy.assert_image
	castor barlito:castor:wait-db-container --service=$(db_service) --php-service=$(main_service) --stack=$(stack_name)
	$(MAKE) deploy.migrate
	@rm -f "$(recover_state)"
	$(MAKE) deploy.workers.start
	$(MAKE) smoke.test
	$(MAKE) deploy.prune

# docker stack deploy resets every replica count to the compose value: the workers are deployed at 0 and started once migrated
drain_override = { printf 'services:\n'; $(foreach w,$(worker_services),printf '  %s:\n    deploy:\n      replicas: 0\n' $(call worker_name,$(w)); )}

deploy.stack:
	@$(if $(worker_services),f="$$(mktemp)" || exit 1; trap 'rm -f "$$f"' EXIT; $(drain_override) > "$$f"; $(MAKE) docker.deploy.prod prod_compose_override="$$f",$(MAKE) docker.deploy.prod)

# Exact-label lookup: doctrine.migrate relies on app_container_id, a name filter that can return several IDs
deploy.migrate:
	@$(app_cid); \
	[ -n "$$acid" ] || { echo "Container of $(stack_name)_$(main_service) not found, cannot migrate"; exit 1; }; \
	docker exec -t "$$acid" bin/console doctrine:database:create --if-not-exists || exit 1; \
	docker exec -t "$$acid" bin/console doctrine:migrations:migrate --no-interaction --allow-no-migration

deploy.update:
	$(require_tag)
	@$(require_castor)
	@rm -f "$(recover_state)"
	$(MAKE) db.backup
	$(MAKE) deploy.workers.drain
	$(MAKE) docker.service.update args="--with-registry-auth --image $(image_name):$(TAG) $(stack_name)_$(main_service)"
	$(MAKE) deploy.assert_image
	castor barlito:castor:wait-php-container --service=$(main_service) --stack=$(stack_name)
	$(MAKE) deploy.migrate
	$(MAKE) deploy.workers.update
	$(MAKE) smoke.test
	$(MAKE) deploy.prune

# Never leave the workers scaled down after a failed deploy, unless they cannot safely run: after a rollback
# touched the database they go back on the rollback tag image, and when the database state is unknown they stay drained
deploy.recover:
	@state=""; [ ! -f "$(recover_state)" ] || state="$$(cat "$(recover_state)")"; \
	case "$$state" in \
		"") $(MAKE) deploy.workers.scale_up;; \
		unsafe) $(if $(worker_services),echo "ERROR: workers stay drained: the database and the images may not match. Fix the cause and rerun the deploy or the rollback; deploy.workers.scale_up forces them up."; exit 1,rm -f "$(recover_state)");; \
		*[!A-Za-z0-9._-]*) echo "ERROR: unreadable $(recover_state), workers left as they are"; exit 1;; \
		*) $(MAKE) deploy.workers.rollback_image rollback_tag="$$state" && $(MAKE) deploy.workers.scale_up && rm -f "$(recover_state)";; \
	esac

deploy.workers.rollback_image:
	$(foreach w,$(worker_services),$(MAKE) docker.service.update args="--with-registry-auth --image $(worker_image_name):$(rollback_tag) $(stack_name)_$(call worker_name,$(w))"$(nl))

deploy.workers.drain:
	$(foreach w,$(worker_services),docker service scale $(stack_name)_$(call worker_name,$(w))=0$(nl))

deploy.workers.scale_up:
	$(foreach w,$(worker_services),docker service scale $(stack_name)_$(call worker_name,$(w))=$(call worker_replicas,$(w))$(nl))

deploy.workers.update:
	$(foreach w,$(worker_services),$(MAKE) deploy.worker.update worker=$(w)$(nl))

deploy.workers.start:
	$(foreach w,$(worker_services),$(MAKE) deploy.worker.start worker=$(w)$(nl))

deploy.worker.start:
	docker service scale $(stack_name)_$(call worker_name,$(worker))=$(call worker_replicas,$(worker))
	$(MAKE) deploy.assert_image assert_service=$(call worker_name,$(worker)) assert_image=$(worker_image_name)

deploy.worker.update:
	$(MAKE) docker.service.update args="--with-registry-auth --image $(worker_image_name):$(TAG) $(stack_name)_$(call worker_name,$(worker))"
	docker service scale $(stack_name)_$(call worker_name,$(worker))=$(call worker_replicas,$(worker))
	$(MAKE) deploy.assert_image assert_service=$(call worker_name,$(worker)) assert_image=$(worker_image_name)

# TAG=<tag> required; RESTORE=1|<dump file> restores the DB instead of reverting migrations
rollback:
	$(require_tag)
	@$(require_castor)
	@rm -f "$(recover_state)"
	$(MAKE) rollback.check
	$(MAKE) rollback.resolve
	$(MAKE) db.backup backup_label=rollback
	$(MAKE) deploy.workers.drain
	@echo unsafe > "$(recover_state)"
	$(MAKE) rollback.database
	@echo "$(TAG)" > "$(recover_state)"
	$(MAKE) docker.service.update args="--with-registry-auth --image $(image_name):$(TAG) $(stack_name)_$(main_service)"
	$(MAKE) deploy.assert_image
	$(MAKE) deploy.workers.update
	@rm -f "$(recover_state)"
	$(MAKE) smoke.test
	$(MAKE) deploy.prune
	@rm -f "$(rollback_state)"

rollback.check:
	$(require_tag)
	castor barlito:castor:migrations-rollback-target $(TAG) --dir=$(migrations_dir) --namespace=$(migrations_namespace)

# RESTORE=1 selects the newest dump taken while $(TAG) was the running version; the rollback backup has another name and is never selected
rollback.resolve:
	@rm -f "$(rollback_state)"; \
	case "$(RESTORE)" in ""|0|false) exit 0;; esac; \
	$(db_cid); \
	[ -n "$$cid" ] || { echo "DB container not found, cannot restore"; exit 1; }; \
	dump="$(RESTORE)"; \
	case "$$dump" in 1|true|latest) \
		case "$(TAG)" in *[!A-Za-z0-9._-]*) echo "TAG '$(TAG)' has characters not allowed in a dump name"; exit 1;; esac; \
		glob="$(stack_name)-$(TAG)-$(ts_glob).dump";; \
	esac; \
	$(find_dump); \
	echo "$$dump" > "$(rollback_state)"; \
	echo "Will restore $$dump"

rollback.database:
	$(if $(filter-out 0 false,$(RESTORE)),$(MAKE) db.restore dump_file=$(rollback_state),$(MAKE) rollback.migrations)

# Runs in the current (newer) php container, which holds the down() code; reverts the added migrations recorded as applied, newest first
rollback.migrations:
	$(require_postgres)
	@out="$$(mktemp)"; trap 'rm -f "$$out"' EXIT; \
	castor barlito:castor:migrations-rollback-target $(TAG) --dir=$(migrations_dir) --namespace=$(migrations_namespace) --output="$$out" || exit 1; \
	if [ ! -s "$$out" ]; then \
		echo "No migration to revert"; \
	else \
		$(db_cid); \
		[ -n "$$cid" ] || { echo "DB container not found, cannot read the applied migrations"; exit 1; }; \
		$(app_cid); \
		[ -n "$$acid" ] || { echo "Container of $(stack_name)_$(main_service) not found, cannot revert the migrations"; exit 1; }; \
		applied="$$(docker exec "$$cid" psql -U $(db_user) -d $(db_name) -tA -c 'SELECT version FROM doctrine_migration_versions')" \
			|| { echo "Cannot read doctrine_migration_versions (table missing?)"; exit 1; }; \
		while IFS= read -r version || [ -n "$$version" ]; do \
			if printf '%s\n' "$$applied" | grep -Fxq -- "$$version"; then \
				docker exec -t "$$acid" bin/console doctrine:migrations:execute --down "$$version" --no-interaction || exit 1; \
			else \
				echo "Skipping $$version: not applied"; \
			fi; \
		done < "$$out"; \
	fi

# Custom format (-F c) dump in the host volume $(backup_path), mounted on /backups in the db container; only deploy.prod may skip it (first deploy)
# Named <stack>-<running version>-<ts>.dump; backup_label=<x> gives <stack>_<x>-<ts>.dump and an unknown version <stack>_unversioned-<ts>.dump (rollback never selects those)
db.backup:
	$(require_postgres)
	@case "$(backup_keep)" in ""|*[!0-9]*) echo "backup_keep must be a number, 0 keeps every dump"; exit 1;; esac; \
	$(db_cid); \
	if [ -n "$$cid" ]; then \
		ts="$$(date +%Y%m%d-%H%M%S)"; \
		if [ -n "$(backup_label)" ]; then prefix="$(stack_name)_$(backup_label)"; \
		else \
			$(running_version); \
			if [ -n "$$version" ]; then prefix="$(stack_name)-$$version"; else prefix="$(stack_name)_unversioned"; fi; \
		fi; \
		echo "DB backup -> $(backup_path)/$$prefix-$$ts.dump (container $$cid)"; \
		docker exec -t "$$cid" sh -c "pg_dump -U $(db_user) -F c -d $(db_name) -f /backups/$$prefix-$$ts.dump" || exit 1; \
		if [ "$(backup_keep)" -gt 0 ]; then \
			docker exec "$$cid" sh -c "ls -1 /backups/$$prefix-$(ts_glob).dump 2>/dev/null | sort -r | tail -n +$$(($(backup_keep) + 1)) | xargs -r rm -f --" \
				|| echo "Backup retention failed, the new dump is kept"; \
		fi; \
	elif [ -n "$(backup_optional)" ]; then \
		echo "DB container not found, backup skipped (first deploy?)"; \
	else \
		echo "DB container $(stack_name)_$(db_service) not found: refusing to continue without a backup"; \
		exit 1; \
	fi

# dump=<file name in $(backup_path)>, or 1/latest for the newest backup of any kind; dump_file=<path> reads the name from a file
# Schema reset and restore run in one transaction
db.restore:
	$(require_postgres)
	@$(db_cid); \
	[ -n "$$cid" ] || { echo "DB container not found, cannot restore"; exit 1; }; \
	dump="$(dump)"; \
	[ -z "$(dump_file)" ] || dump="$$(cat "$(dump_file)")"; \
	glob="$(stack_name)[-_]*.dump"; \
	$(find_dump); \
	echo "DB restore <- $(backup_path)/$$dump (container $$cid)"; \
	docker exec -i "$$cid" sh -c '$(restore_script)' sh "$$dump" "$(reset_sql)" </dev/null

# Swarm rollbacks exit 0: fail unless the service really runs the tag, healthy (castor task)
deploy.assert_image:
	$(require_tag)
	$(if $(assert_image),,$(error image_name is required))
	castor barlito:castor:assert-deployed $(stack_name)_$(assert_service) $(assert_image):$(TAG) --timeout=$(assert_timeout) --settle=$(assert_settle)

# Removes the stack's stopped containers (old tasks); prune never touches running ones
deploy.prune:
	docker container prune -f --filter label=com.docker.stack.namespace=$(stack_name)

# Fails on 4xx/5xx; a redirect to a login page proves the app answers. Retried as a whole: on a first deploy the TLS
# handshake fails until Traefik holds its certificate, which curl --retry does not retry
smoke.test:
	@echo "Smoke test https://$(prod_host)$(smoke_path)"
	@i=1; until curl -fsS --connect-timeout 10 --max-time 30 -o /dev/null -w "  HTTP %{http_code}\n" https://$(prod_host)$(smoke_path); do \
		if [ "$$i" -ge "$(smoke_retries)" ]; then echo "Smoke test FAILED"; exit 1; fi; \
		echo "  attempt $$i/$(smoke_retries) failed, retrying in $(smoke_delay)s"; i=$$((i + 1)); sleep $(smoke_delay); \
	done
	@echo "Smoke test OK"
