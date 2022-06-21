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

docker.undeploy:
	docker stack rm $(stack_name)

### CI rules
docker.deploy.ci:
	docker-compose pull
	docker-compose -p $(stack_name) -f docker-compose.yml -f docker-compose-ci.yml up -d

docker.undeploy.ci:
	docker-compose -p $(stack_name) down

docker.wait_stack:
	until $$(curl -sI "http://$(project_url)/" | grep -q 'Server: nginx') ; do \
    	printf '.' ; \
    	sleep 0.5 ; \
    done

docker.wait_stack.ci:
	until $$(curl -sI http://localhost:8081/ | grep -q 'Server: nginx') ; do \
    	printf '.' ; \
    	sleep 0.5 ; \
    done