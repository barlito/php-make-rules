### Development rules

docker.deploy:
	docker-compose pull
	docker stack deploy -c docker-compose.yml $(stack_name)

docker.undeploy:
	docker stack rm $(stack_name)

docker.bash:
	docker exec -it -u root $(app_container_id) bash
