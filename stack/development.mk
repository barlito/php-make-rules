### Development rules

bash:
	make docker.bash

deploy:
	make docker.deploy
	make docker.wait_stack
	make composer.install
	make doctrine.migrate
	make doctrine.load_fixtures
	make symfony.security_check

undeploy:
	make docker.undeploy
