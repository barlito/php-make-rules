### Behat rules

behat.install:
	docker exec -t $(app_container_id) bash -c "composer require behat/behat -W --dev"

behat.init:
	docker exec -t $(app_container_id) bash -c "php vendor/bin/behat --init"

behat:
	docker exec -t $(app_container_id) bash -c "php vendor/bin/behat $(BEHAT_OPT)"
