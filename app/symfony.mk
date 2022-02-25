### Symfony rules

symfony.install:
	rm -rf app/.gitkeep
	docker exec -t $(app_container_id) bash -c "composer create-project symfony/skeleton ./"

symfony.security_check:
	docker run --rm -v $(shell pwd):$(shell pwd) -w $(shell pwd)/app symfonycorp/cli security:check

