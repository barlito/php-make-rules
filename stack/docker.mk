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
	docker-compose pull
	docker stack deploy -c docker-compose.yml $(stack_name)

### CI rules
docker.deploy.ci:
	docker-compose pull
	docker-compose -p $(stack_name) -f docker-compose.yml -f docker-compose-ci.yml up -d

### Prod rules
docker.deploy.prod:
	docker-compose pull
	docker stack deploy -c docker-compose-prod.yml $(stack_name)

docker.service.update:
	docker service update $(args)

docker.undeploy:
	docker stack rm $(stack_name)

docker.undeploy.ci:
	docker-compose -p $(stack_name) down

docker.wait_stack:
	until $$(curl -ksI "https://$(project_url)/" | grep -iq 'Server: nginx') ; do \
    	printf '.' ; \
    	sleep 0.5 ; \
    done

docker.wait_stack.ci:
	until $$(curl -sI http://localhost:8081/ | grep -q 'Server: nginx') ; do \
    	printf '.' ; \
    	sleep 0.5 ; \
    done