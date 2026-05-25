<?php

namespace Barlito\Castor;

use Castor\Attribute\AsTask;
use Castor\Exception\WaitFor\DockerContainerStateException;

use function Castor\io;
use function Castor\context;
use function Castor\wait_for_docker_container;

#[AsTask('wait-php-container')]
function waitPhpContainer(int $attempt = 0): void
{
    $context = context();
    $STACK_NAME = $context->environment['STACK_NAME'];
    $containerName = "{$STACK_NAME}_php";
    $maxAttempts = 60;

    if ($attempt > 0) {
        io()->info("Retrying ({$attempt}/{$maxAttempts})...");
    } else {
        io()->info("Waiting for container {$containerName} to start...");
    }

    try {
        wait_for_docker_container(
            containerName: $containerName,
            message: "Checking if {$containerName} is running...",
        );
        io()->success("PHP container is running!");
    } catch (DockerContainerStateException $e) {
        if ($attempt >= $maxAttempts) {
            io()->error("Container {$containerName} is not running after {$maxAttempts} retries.");
            throw $e;
        }
        sleep(1);
        waitPhpContainer($attempt + 1);
    }
}

#[AsTask('wait-db-container')]
function waitDbContainer(int $attempt = 0): void
{
    $context = context();
    $STACK_NAME = $context->environment['STACK_NAME'];
    $dbContainer = "{$STACK_NAME}_db";
    $maxAttempts = 60;

    if ($attempt > 0) {
        io()->info("Retrying ({$attempt}/{$maxAttempts})...");
    } else {
        io()->info("Waiting for database container {$dbContainer} to be ready...");
    }

    try {
        wait_for_docker_container(
            containerName: $dbContainer,
            message: "Checking if {$dbContainer} is running and healthy...",
        );
        io()->success("Database container is ready!");
    } catch (DockerContainerStateException $e) {
        if ($attempt >= $maxAttempts) {
            io()->error("Database container {$dbContainer} is not ready after {$maxAttempts} retries.");
            throw $e;
        }
        sleep(1);
        waitDbContainer($attempt + 1);
    }
}
