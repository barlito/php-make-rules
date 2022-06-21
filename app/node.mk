### Node rules

### Default rule
node.default:
	make docker.run \
		exec_params="-it --rm --name $(stack_name)_node -p 8081:8081/tcp -v $(shell pwd)/app:/usr/src/app -w /usr/src/app" \
		docker_image="node:18" \
		container_command="$(container_command)"

### Node rules

### Yarn rules
yarn:
	make node.default container_command=yarn

yarn.dev-server:
	make yarn
	make node.default container_command="yarn dev-server"
