### Package rules

package.barlito_utils.install:
	docker exec -t $(app_container_id) bash -c "composer config repositories.barlito/utils vcs https://github.com/barlito/utils"
	docker exec -t $(app_container_id) bash -c "composer require barlito/utils"