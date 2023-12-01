### Symfony rules

symfony.install:
	rm -rf app/.gitkeep
	docker exec -t $(app_container_id) bash -c "composer create-project symfony/skeleton ./app"
	mv app/* ./ && mv app/.* ./ && rm -rf app

symfony.security_check:
	docker run --rm -v ./:/app -w /app ghcr.io/symfony-cli/symfony-cli security:check

