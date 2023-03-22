### Deployment rules

deploy.prod:
	make docker.deploy.prod
	make docker.wait_stack
	make permissions
	make doctrine.migrate

update.service:
	make docker.service.update args="$(service_update_args)"
	make docker.wait_stack
	make permissions
	make doctrine.migrate