<?php


namespace Barlito\Castor;

use Castor\Attribute\AsTask;

use function Castor\wait_for_docker_container;

#[AsTask('wait-nginx-container')]
function waitNginxContainer(): void {
    wait_for_docker_container(
        containerName: '$STACK_NAME_nginx',
//        portsToCheck: [80, 443],
        message: 'Waiting for my-container to be ready...',
    );
}