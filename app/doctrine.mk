### Doctrine rules

doctrine.migrate:
	docker exec -t $(app_container_id) bin/console doctrine:database:create --if-not-exists
	docker exec -t $(app_container_id) bin/console doctrine:migrations:migrate --no-interaction --allow-no-migration

doctrine.migrate.ci:
	docker exec -t $(app_container_id) bin/console doctrine:database:create --if-not-exists --env=test
	docker exec -t $(app_container_id) bin/console doctrine:migrations:migrate --no-interaction --allow-no-migration --env=test

doctrine.reset_db:
	docker exec -t $(app_container_id) bin/console doctrine:database:drop --force --if-exists
	docker exec -t $(app_container_id) bin/console doctrine:database:create --if-not-exists

doctrine.load_fixtures:
	docker exec -t $(app_container_id) bin/console hautelook:fixtures:load -n

doctrine.load_fixtures.ci:
	docker exec -t $(app_container_id) bin/console hautelook:fixtures:load -n --env=test
