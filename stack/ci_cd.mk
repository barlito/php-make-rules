### CI/CD rules

deploy.ci:
	make docker.deploy.ci
	make docker.wait_stack.ci
	make composer.command args="config -g github-oauth.github.com $(args)"
	make composer.install
	make docker.command exec_params="-t" args="chmod +x bin/console"
	make doctrine.migrate
	make doctrine.load_fixtures
	#make symfony.security_check