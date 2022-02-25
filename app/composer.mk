### Composer rules

composer.install:
	docker exec -t $(app_container_id) composer install --optimize-autoloader --no-interaction

