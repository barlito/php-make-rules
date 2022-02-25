### Composer rules

composer.command:
	docker exec -t $(app_container_id) bash -c "composer $(args)"

composer.require:
	docker exec -t $(app_container_id) bash -c "composer require $(args)"

composer.install:
	docker exec -t $(app_container_id) bash -c "composer install --optimize-autoloader --no-interaction"

