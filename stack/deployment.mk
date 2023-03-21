### Deployment rules

deploy.prod:
	make docker.deploy.prod
	make docker.wait_stack
	make permissions
	make doctrine.migrate