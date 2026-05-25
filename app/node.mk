### Node rules

node_image ?= node:22
node_exec_params=--rm -v $(shell pwd):/app -w /app

### npm rules
npm.command:
	docker run $(node_exec_params) $(node_image) npm $(args)

npm.install:
	make npm.command args="install"

npm.build:
	make npm.command args="run build"

npm.dev:
	make npm.command args="run dev"

npm.watch:
	make npm.command args="run watch"

### Yarn rules
yarn.command:
	docker run $(node_exec_params) $(node_image) yarn $(args)

yarn.install:
	make yarn.command args="install"

yarn.build:
	make yarn.command args="build"

yarn.dev:
	make yarn.command args="dev"
