### Symfony rules

symfony.install:
	rm -Rf tmp/
	docker exec -t $(app_container_id) bash -c "composer create-project symfony/skeleton tmp --prefer-dist --no-progress --no-interaction"
	sudo chown -R $(shell id -u):$(shell id -g) .
	cd tmp && cp -Rp . .. && cd -
	rm -Rf tmp/

symfony.security_check:
	docker run --rm -v ./:/app -w /app ghcr.io/symfony-cli/symfony-cli security:check

