### Vars
exec_params=-it

### Basic rules
docker.bash:
	docker exec $(exec_params) $(app_container_id) bash

docker.command:
	docker exec $(exec_params) $(app_container_id) bash -c "$(args)"

docker.run:
	docker run $(exec_params) $(docker_image) $(container_command)

### Development rules
docker.deploy:
	docker compose pull || true
	docker compose build
	docker stack deploy -c docker-compose.yml $(stack_name)

### CI rules
docker.deploy.ci:
	docker compose -f docker-compose.yml -f docker-compose-ci.yml pull || true
	docker compose -f docker-compose.yml -f docker-compose-ci.yml build
	docker compose -p $(stack_name) -f docker-compose.yml -f docker-compose-ci.yml up -d

### Prod rules
# Waits for convergence; on timeout deploy.assert_image reports the failing service
docker.deploy.prod:
	docker compose -f $(prod_compose_file) pull
	@timeout $(deploy_timeout) docker stack deploy --detach=false -c $(prod_compose_file) $(stack_name) \
		|| { rc=$$?; [ $$rc -eq 124 ] && echo "$(stack_name) not converged after $(deploy_timeout)s"; [ $$rc -eq 124 ]; }

docker.service.update:
	docker service update $(args)

docker.undeploy:
	docker stack rm $(stack_name)

docker.undeploy.ci:
	docker compose -p $(stack_name) down