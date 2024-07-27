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
docker.deploy.prod:
	docker compose -f docker-compose-prod.yml pull || true
	docker compose -f docker-compose.yml -f docker-compose-prod.yml build
	docker stack deploy -c docker-compose-prod.yml $(stack_name)

docker.service.update:
	docker service update $(args)

docker.undeploy:
	docker stack rm $(stack_name)

docker.undeploy.ci:
	docker compose -p $(stack_name) down