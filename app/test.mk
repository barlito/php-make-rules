### Test rules

phpunit:
	docker exec -it -u root $(app_container_id) ./vendor/bin/simple-phpunit $(PHPUNIT_OPT) --colors=always
