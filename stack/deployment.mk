### Deployment rules

bash:
	make docker.bash

### Development rules
deploy:
	make docker.deploy
	castor barlito:castor:wait-php-container
	make composer.install
	castor barlito:castor:wait-db-container
	make doctrine.migrate
	make doctrine.load_fixtures
	make symfony.security_check

### CI/CD rules
deploy.ci:
	make docker.deploy.ci
	castor barlito:castor:wait-php-container
	make composer.command args="config -g github-oauth.github.com $(github_token)"
	make composer.install
	make docker.command exec_params="-t" args="chmod +x bin/console"
	castor barlito:castor:wait-db-container
	make doctrine.migrate.ci
	make doctrine.load_fixtures.ci
	#make symfony.security_check

### Prod rules
deploy.prod:
	make docker.deploy.prod
	castor barlito:castor:wait-php-container
	castor barlito:castor:wait-db-container
	make doctrine.migrate

update.service:
	make docker.service.update args="$(service_update_args)"
	castor barlito:castor:wait-php-container
	castor barlito:castor:wait-db-container
	make doctrine.migrate

undeploy:
	make docker.undeploy
