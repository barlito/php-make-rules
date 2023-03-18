### Deployment rules

deploy.prod:
	make docker.deploy.prod
	make docker.wait_stack
	make composer.install
	make doctrine.migrate