### Deployment rules

bash:
	make docker.bash

### Development rules
deploy:
	make set_file_permissions
	make docker.deploy
	castor barlito:castor:wait-php-container
	make composer.install
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
	make doctrine.migrate.ci
	make doctrine.load_fixtures.ci
	#make symfony.security_check

### Prod rules
deploy.prod:
	make docker.deploy.prod
	castor barlito:castor:wait-php-container
	make doctrine.migrate

update.service:
	make docker.service.update args="$(service_update_args)"
	make docker.wait_stack
	make doctrine.migrate

undeploy:
	make docker.undeploy

set_file_permissions:
	sudo setfacl -R -m u:`whoami`:rwx -m g:`whoami`:rwx -m o:rwx -m m:rwx . && sudo setfacl -R -d -m u:`whoami`:rwx -m g:`whoami`:rwx -m o:rwx -m m:rwx . 2>/dev/null
