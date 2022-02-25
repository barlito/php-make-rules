### phpunit rules

phpunit.install:
	docker exec -t $(app_container_id) bash -c "composer require --dev symfony/test-pack"

phpunit:
	docker exec -t $(app_container_id) bash -c "php bin/phpunit $(PHPUNIT_OPT) --colors=always"
