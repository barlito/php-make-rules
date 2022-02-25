### Code style rules

CSFIXER_OPT ?=
RECTOR_OPT ?=

check_style:
	make phpcs
	make phpmd
	make cs_fixer.dry_run

phpcs.install:
	docker exec -t $(app_container_id) bash -c "composer require --no-interaction --dev squizlabs/php_codesniffer"

phpcs:
	docker exec -t $(app_container_id) vendor/bin/phpcs --standard=$(config_phpcs) src/ tests/

phpmd.install:
	docker exec -t $(app_container_id) bash -c "composer require --dev phpmd/phpmd"

phpmd:
	docker exec -t $(app_container_id) vendor/bin/phpmd src/ ansi $(config_phpmd) --exclude src/Migrations/,tests/

cs_fixer.install:
	docker exec -t $(app_container_id) bash -c "composer require --dev friendsofphp/php-cs-fixer"

cs_fixer:
	docker exec -t $(app_container_id) php -d "memory_limit=-1" vendor/bin/php-cs-fixer fix --diff --config=$(config_cs_fixer) $(CSFIXER_OPT)

cs_fixer.dry_run:
	docker exec -t $(app_container_id) php -d "memory_limit=-1" vendor/bin/php-cs-fixer fix --dry-run --diff --config=$(config_cs_fixer) $(CSFIXER_OPT)
