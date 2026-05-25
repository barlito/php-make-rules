### Code style rules

CSFIXER_OPT ?=
PHPSTAN_OPT ?=
RECTOR_OPT ?=

### Batch install
code_quality.install:
	make phpcs.install
	make phpmd.install
	make cs_fixer.install
	make phpstan.install
	make rector.install

test.install:
	make phpunit.install
	make behat.install
	make behat.init

### Aggregate checks
check_style:
	make phpcs
	make phpmd
	make cs_fixer.dry_run
	make phpstan
	make rector.dry_run

### Aggregate fixes
fix_style:
	make cs_fixer
	make rector

### PHP CodeSniffer
phpcs.install:
	docker exec -t $(app_container_id) bash -c "composer require --no-interaction --dev squizlabs/php_codesniffer"

phpcs:
	docker exec -t $(app_container_id) vendor/bin/phpcs --standard=$(config_phpcs) src/ tests/

### PHP Mess Detector
phpmd.install:
	docker exec -t $(app_container_id) bash -c "composer require --dev phpmd/phpmd"

phpmd:
	docker exec -t $(app_container_id) vendor/bin/phpmd src/ ansi $(config_phpmd) --exclude src/Migrations/,tests/

### PHP CS Fixer
cs_fixer.install:
	docker exec -t $(app_container_id) bash -c "composer require --dev friendsofphp/php-cs-fixer"

cs_fixer:
	docker exec -t $(app_container_id) php -d "memory_limit=-1" vendor/bin/php-cs-fixer fix --diff --config=$(config_cs_fixer) $(CSFIXER_OPT)

cs_fixer.dry_run:
	docker exec -t $(app_container_id) php -d "memory_limit=-1" vendor/bin/php-cs-fixer fix --dry-run --diff --config=$(config_cs_fixer) $(CSFIXER_OPT)

### PHPStan
phpstan.install:
	docker exec -t $(app_container_id) bash -c "composer require --dev phpstan/phpstan phpstan/phpstan-symfony phpstan/phpstan-doctrine"

phpstan:
	docker exec -t $(app_container_id) php -d "memory_limit=512M" vendor/bin/phpstan analyse $(PHPSTAN_OPT)

### Rector
rector.install:
	docker exec -t $(app_container_id) bash -c "composer require --dev rector/rector"

rector:
	docker exec -t $(app_container_id) vendor/bin/rector process $(RECTOR_OPT)

rector.dry_run:
	docker exec -t $(app_container_id) vendor/bin/rector process --dry-run $(RECTOR_OPT)
