### Node rules

node_ports=
node_container_name="$(stack_name)_node"
node_exec_params="-it --rm --name $(node_container_name) $(ports) -v $(shell pwd)/app:/usr/src/app -w /usr/src/app"

### Default rule
node.default:
	make docker.run \
		exec_params=$(node_exec_params) \
		docker_image="node:18" \
		container_command="$(container_command)"

### Node rules

### Yarn rules
yarn:
	make node.default container_command="yarn $(args)"

yarn.dev-server:
	make yarn
	make node.default \
 		container_command="yarn dev-server" \
 		node_container_name="$(node_container_name)_dev_server" \
		ports="-p 8081:8081/tcp"
