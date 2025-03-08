<?php

namespace Barlito\Castor;

use Castor\Attribute\AsTask;
use Castor\Exception\WaitFor\DockerContainerStateException;

use function Castor\io;
use function Castor\context;
use function Castor\wait_for_docker_container;
use function Castor\run;

#[AsTask('wait-php-container')]
function waitNginxContainer($loopCount = 0): void
{
    $context = context();
    $STACK_NAME = $context->environment['STACK_NAME'];

    try {
        wait_for_docker_container(
            containerName: '${STACK_NAME}_php',
//          portsToCheck: [80, 443],
            message: "Waiting for Container {$STACK_NAME}_php to be ready...",
        );
    } catch (DockerContainerStateException $exception) {
        if($loopCount > 60) {
            throw $exception;
        }

        io()->info("Waiting for Container {$STACK_NAME}_php to be ready..." . $loopCount);
        sleep(1);
        waitNginxContainer($loopCount + 1);
    }
}

#[AsTask('wait-db-container')]
function waitDatabaseContainer($dbName = null, $loopCount = 0): void
{
    $context = context();
    $STACK_NAME = $context->environment['STACK_NAME'];
    $DB_NAME = $context->environment['DB_NAME'];
    if ($dbName === null) {
        $dbName = $DB_NAME;
    }

    try {
        wait_for_docker_container(
            containerName: '${STACK_NAME}_db',
            message: "Waiting for Container {$STACK_NAME}_db to be ready...",
            containerChecker: function ($containerId) use ($dbName) {
                return run("docker exec $containerId pg_isready -d " . $dbName, context: context()->withAllowFailure())->isSuccessful();
            },
        );
    } catch (DockerContainerStateException $exception) {
        if ($loopCount > 60) {
            throw $exception;
        }

        io()->info("Waiting for Container {$STACK_NAME}_db to be ready..." . $loopCount);
        sleep(1);
        waitDatabaseContainer($dbName, $loopCount + 1);
    }
}
