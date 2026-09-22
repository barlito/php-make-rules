<?php

namespace Barlito\Castor;

use Castor\Attribute\AsTask;

use function Castor\capture;
use function Castor\context;
use function Castor\io;
use function Castor\run;

function runningContainerId(string $name): string
{
    $ids = trim(capture(
        ['docker', 'ps', '-q', '--filter', "name={$name}", '--filter', 'status=running'],
        context: context()->withAllowFailure(),
    ));

    return '' === $ids ? '' : strtok($ids, "\n");
}

function containerHealth(string $id): string
{
    return trim(capture(
        ['docker', 'inspect', '-f', '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}', $id],
        context: context()->withAllowFailure(),
    ));
}

function waitForReadyContainer(string $name, int $maxAttempts = 90, int $intervalSeconds = 2): string
{
    for ($attempt = 1; $attempt <= $maxAttempts; ++$attempt) {
        $id = runningContainerId($name);
        if ('' !== $id && \in_array(containerHealth($id), ['healthy', 'none'], true)) {
            return $id;
        }
        io()->info("Retrying ({$attempt}/{$maxAttempts})...");
        sleep($intervalSeconds);
    }

    io()->error("Container {$name} is not ready after {$maxAttempts} retries.");

    throw new \RuntimeException("Container {$name} is not ready after {$maxAttempts} attempts.");
}

#[AsTask('wait-php-container')]
function waitPhpContainer(): void
{
    $STACK_NAME = context()->environment['STACK_NAME'];
    $containerName = "{$STACK_NAME}_php";

    io()->info("Waiting for container {$containerName} to start...");
    waitForReadyContainer($containerName);
    io()->success("PHP container is running!");
}

#[AsTask('wait-db-container')]
function waitDbContainer(): void
{
    $STACK_NAME = context()->environment['STACK_NAME'];
    $dbContainer = "{$STACK_NAME}_db";
    $phpContainer = "{$STACK_NAME}_php";

    io()->info("Waiting for database container {$dbContainer} to be ready...");
    waitForReadyContainer($dbContainer);
    io()->success("Database container is ready!");

    $phpContainerId = runningContainerId($phpContainer);
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
