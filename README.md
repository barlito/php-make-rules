# barlito/php-make-rules

Reusable Make + Castor rules for Symfony projects. Designed as a git submodule.

## Setup

```bash
git submodule add git@github.com:barlito/php-make-rules.git make
```

In your `Makefile`:

```makefile
# Required variables
stack_name=my_project
app_container_id = $(shell docker ps --filter name="$(stack_name)_php" -q)

# Config paths (from barlito/utils)
config_cs_fixer=vendor/barlito/utils/config/.php-cs-fixer.dist.php
config_phpcs=vendor/barlito/utils/config/phpcs.xml.dist
config_phpmd=vendor/barlito/utils/config/phpmd.xml

# Include all rules
include make/entrypoint.mk
```

In your `castor.php`:

```php
import('make/castor_entrypoint.php');
```

## Available Rules

### App (`app/`)

| Rule | Description |
|------|-------------|
| `composer.install` | Install deps (optimized autoloader) |
| `composer.update` | Update deps |
| `composer.require` | Require package (`args="vendor/pkg"`) |
| `composer.outdated` | Show outdated direct deps |
| `composer.validate` | Validate composer.json |
| `cs_fixer` / `cs_fixer.dry_run` | PHP CS Fixer (fix / check) |
| `phpcs` | PHP CodeSniffer |
| `phpmd` | PHP Mess Detector |
| `phpstan` | PHPStan static analysis |
| `rector` / `rector.dry_run` | Rector refactoring |
| `check_style` | Run composer.validate + phpcs + phpmd + cs_fixer.dry_run |
| `phpunit` | Run PHPUnit tests |
| `behat` / `behat.init` | Run/init Behat |
| `doctrine.migrate` | Create DB + run migrations |
| `doctrine.diff` | Generate migration from entity diff |
| `doctrine.reset_db` | Drop + recreate database |
| `doctrine.load_fixtures` | Load Hautelook fixtures |
| `symfony.install` | Create Symfony skeleton project |
| `symfony.security_check` | Security vulnerability check |
| `npm.*` | npm commands via disposable container |
| `yarn.*` | yarn commands via disposable container |

### Stack (`stack/`)

| Rule | Description |
|------|-------------|
| `docker.deploy` | Build + deploy dev stack (Swarm) |
| `docker.deploy.ci` | Deploy CI stack (compose up) |
| `docker.deploy.prod` | Pull and `docker stack deploy --detach=false` the prod compose file, bounded by `deploy_timeout` |
| `docker.undeploy` | Remove Swarm stack |
| `docker.undeploy.ci` | Remove CI containers |
| `docker.bash` | Shell into PHP container |
| `docker.command` | Run command in container (`args="..."`) |
| `docker.service.update` | Update a Swarm service |
| `deploy` | Full dev deploy (build + install + migrate + fixtures) |
| `deploy.ci` | Full CI deploy |
| `undeploy` | Remove stack |

### Production (`stack/prod.mk`)

| Rule | Description |
|------|-------------|
| `deploy.prod` | Full rolling `docker stack deploy` of the prod compose file (creates the stack on a first deploy, never `stack rm`): backup, deploy, assert images, wait db, migrate, smoke, prune |
| `deploy.update` | Rolling image update (`TAG`): backup, drain workers, update main service, assert, migrate, update workers, smoke, prune |
| `rollback` | `TAG=<tag>` required. Backup (mandatory), then reverts exactly the Doctrine migrations added since the tag (`migrations:execute --down`, newest first), then rolls the images back. `RESTORE=1\|<dump file>` restores a dump (resolved before the rollback backup) instead of reverting migrations |
| `deploy.recover` | Rescale the workers to their replicas after a failed deploy |
| `db.backup` | `pg_dump` into `/backups` of the db container; fails when the db container is missing, except with `backup_optional=1` (set by `deploy.prod` for a first deploy) |
| `db.restore` | `dump=<file>` or `dump=1` (newest backup): drops and recreates `db_schemas`, then `pg_restore --single-transaction` |
| `deploy.assert_image` | Fail unless `assert_service` runs `assert_image:$TAG`, healthy |
| `smoke.test` | `curl` GET `https://$(prod_host)$(smoke_path)`, fails on 4xx/5xx |
| `deploy.prune` | Remove the stack's stopped containers |

Set `stack_name`, `prod_host`, `image_name` (and `worker_image_name` when there are workers) before the include; every target can still be overridden in the project Makefile.

| Variable | Default | Description |
|----------|---------|-------------|
| `stack_name` | none | Swarm stack name |
| `prod_host` | none | Host of the smoke test |
| `image_name` | none | Main service image (no tag; `TAG` is appended) |
| `main_service` | `php` | Main service, without the stack prefix |
| `worker_image_name` | empty | Image of every worker service |
| `worker_services` | `message_worker:1` if `worker_image_name` is set, else empty | Space-separated `service:replicas` (replicas default to 1), e.g. `message_worker:2 mailer` |
| `prod_compose_file` | `docker-compose-prod.yml` | Prod compose file |
| `deploy_timeout` | `300` | Seconds `docker stack deploy` may take |
| `assert_service` / `assert_image` | `main_service` / `image_name` | Arguments of `deploy.assert_image` (was `assert_image_name` in youl-coin-api) |
| `assert_timeout` / `assert_settle` | `180` / `10` | Options of the `assert-deployed` task |
| `db_kind` | `postgres` | Anything else fails in `db.backup` / `db.restore` |
| `db_service` | `db` | Database service, without the stack prefix |
| `db_user` / `db_name` | `stack_name` | Credentials used by `pg_dump` / `pg_restore` |
| `db_schemas` | `public` | Space-separated schemas dropped and recreated before a restore |
| `backup_path` | `/srv/$(stack_name)/backups` | Host directory mounted on `/backups` (display only) |
| `backup_optional` | empty | Non-empty lets `db.backup` skip when no db container exists |
| `smoke_path` | `/` | Path requested by `smoke.test` |
| `migrations_dir` / `migrations_namespace` | `migrations` / `DoctrineMigrations` | Used by the rollback migration detection |

`rollback` needs the git history and tags of the target (`fetch-depth: 0`) to compare the migrations of `TAG` with the working tree.

### Castor Tasks

| Task | Description |
|------|-------------|
| `wait-php-container [--service=php]` | Wait for PHP container to be running and healthy (3 min timeout) |
| `wait-db-container [--service=db] [--php-service=php] [--port=5432]` | Wait for DB container to be healthy and reachable from PHP (3 min timeout) |
| `assert-deployed <service> <image> [--timeout=180] [--settle=10]` | Fail unless the Swarm service runs `<image>` with every replica running, healthy and still the same tasks after `--settle` seconds. Run it after `docker service update` / `docker stack deploy`, which exit 0 even when Swarm rolled the update back |
| `migrations-rollback-target <tag> [--dir] [--namespace] [--output]` | Write, one per line and newest first, the migrations present in the working tree but not in `<tag>` (empty when none); fail on an unknown tag |
| `set-stack-name` | Replace stack name placeholder in project files |

## Overridable Variables

```makefile
CSFIXER_OPT ?=     # Extra options for PHP CS Fixer
PHPSTAN_OPT ?=     # Extra options for PHPStan
RECTOR_OPT ?=      # Extra options for Rector
PHPUNIT_OPT ?=     # Extra options for PHPUnit
BEHAT_OPT ?=       # Extra options for Behat
node_image ?= node:22  # Node.js Docker image
```

## Used By

- [barlito/php-starter](https://github.com/barlito/php-starter)
- [barlito/carapp](https://github.com/barlito/carapp)
- [youl-coin-api](https://github.com/barlito/youl-coin-api)
- [youl-tcg](https://github.com/barlito/youl-tcg)

## Tests

```bash
bash tests/make.sh    # make -n assertions, docker shimmed
bash tests/castor.sh  # castor tasks, in a php container
```
