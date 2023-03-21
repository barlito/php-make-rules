### Permissions rules
permissions:
	make docker.command exec_params="-t" args="setfacl -R -m u:application:rwx -m u:$(whoami):rwx var"
	make docker.command exec_params="-t" args="setfacl -dR -m u:application:rwx -m u:$(whoami):rwx var"
	make docker.command exec_params="-t" args="setfacl -R -m u:application:rwx -m u:$(whoami):rwx src"
	make docker.command exec_params="-t" args="setfacl -dR -m u:application:rwx -m u:$(whoami):rwx src"
