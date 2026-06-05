<?php

namespace Barlito\Castor;

use Castor\Attribute\AsTask;
use Castor\Exception\WaitFor\DockerContainerStateException;

use function Castor\capture;
use function Castor\context;
use function Castor\io;
use function Castor\run;
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

        return;
    }
}

#[AsTask('wait-db-container')]
function waitDbContainer(int $attempt = 0): void
{
    $context = context();
    $STACK_NAME = $context->environment['STACK_NAME'];
    $dbContainer = "{$STACK_NAME}_db";
    $phpContainer = "{$STACK_NAME}_php";
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
        // The recursive call performs the full readiness check (container health
        // AND the DNS probe below). Returning here prevents the parent frames from
        // re-running the DNS probe as the recursion unwinds — otherwise it is
        // executed once per elapsed startup second, spamming the output and making
        // the step look stuck on the first (slow) deploy.
        waitDbContainer($attempt + 1);

        return;
    }

    $phpContainerId = trim(capture("docker ps --filter name={$phpContainer} -q", context: context()->withAllowFailure()));
    if ($phpContainerId === '') {
        io()->warning("PHP container not found, skipping DNS connectivity check.");
        return;
    }

    io()->info("Checking database DNS resolution from PHP container...");
    $dnsMaxAttempts = 30;
    for ($i = 0; $i < $dnsMaxAttempts; $i++) {
        $result = run(
            "docker exec {$phpContainerId} php -r \"@stream_socket_client('tcp://db:5432', \\\$e, \\\$m, 2) ? exit(0) : exit(1);\"",
            context: context()->withAllowFailure()
        );
        if ($result->isSuccessful()) {
            io()->success("Database is reachable from PHP container!");
            return;
        }
        io()->warning("Database not yet reachable from PHP container, retrying... ({$i}/{$dnsMaxAttempts})");
        sleep(2);
    }

    throw new \RuntimeException("Database host 'db' is not reachable from PHP container after {$dnsMaxAttempts} attempts.");
}
