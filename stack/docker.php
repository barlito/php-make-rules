<?php

namespace Barlito\Castor;

use Castor\Attribute\AsTask;
use function Castor\io;
use Castor\Exception\WaitFor\DockerContainerStateException;

use function Castor\wait_for_docker_container;

#[AsTask('wait-php-container')]
function waitNginxContainer(): void
{
    try {
        wait_for_docker_container(
            containerName: '${STACK_NAME}_php',
//          portsToCheck: [80, 443],
            message: 'Waiting for Container to be ready...',
        );
    } catch (DockerContainerStateException) {
        io()->info('Waiting for Container to start...');
        sleep(1);
        waitNginxContainer();
    }
}