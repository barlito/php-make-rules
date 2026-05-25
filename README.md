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
| `check_style` | Run phpcs + phpmd + cs_fixer.dry_run |
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
| `docker.deploy.prod` | Deploy production stack |
| `docker.undeploy` | Remove Swarm stack |
| `docker.undeploy.ci` | Remove CI containers |
| `docker.bash` | Shell into PHP container |
| `docker.command` | Run command in container (`args="..."`) |
| `docker.service.update` | Update a Swarm service |
| `deploy` | Full dev deploy (build + install + migrate + fixtures) |
| `deploy.ci` | Full CI deploy |
| `deploy.prod` | Full prod deploy |
| `undeploy` | Remove stack |

### Castor Tasks

| Task | Description |
|------|-------------|
| `wait-php-container` | Wait for PHP container to be ready (60 retries) |
| `wait-db-container` | Wait for DB container to be healthy (60 retries) |
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
