<?php

namespace Barlito\Castor;

use Castor\Attribute\AsOption;
use Castor\Attribute\AsTask;

use function Castor\capture;
use function Castor\context;
use function Castor\io;
use function Castor\run;

function firstRunningContainerId(string ...$filters): string
{
    $args = ['docker', 'ps', '-q', '--filter', 'status=running'];
    foreach ($filters as $filter) {
        array_push($args, '--filter', $filter);
    }
    $ids = trim(capture($args, context: context()->withAllowFailure()->withQuiet()));

    return '' === $ids ? '' : strtok($ids, "\n");
}

// Swarm service first, then a compose service of the project (CI stacks run with `docker compose up`), then the exact container name
function runningContainerId(string $stack, string $service): string
{
    return firstRunningContainerId("label=com.docker.swarm.service.name={$stack}_{$service}")
        ?: firstRunningContainerId("label=com.docker.compose.project={$stack}", "label=com.docker.compose.service={$service}")
        ?: firstRunningContainerId('name=^/' . preg_quote("{$stack}_{$service}", '/') . '$');
}

function stackName(string $stack): string
{
    return '' !== $stack ? $stack : context()->environment['STACK_NAME'];
}

function containerHealth(string $id): string
{
    return trim(capture(
        ['docker', 'inspect', '-f', '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}', $id],
        context: context()->withAllowFailure(),
    ));
}

function waitForReadyContainer(string $stack, string $service, int $maxAttempts = 90, int $intervalSeconds = 2): string
{
    for ($attempt = 1; $attempt <= $maxAttempts; ++$attempt) {
        $id = runningContainerId($stack, $service);
        if ('' !== $id && \in_array(containerHealth($id), ['healthy', 'none'], true)) {
            return $id;
        }
        io()->info("Retrying ({$attempt}/{$maxAttempts})...");
        sleep($intervalSeconds);
    }

    $name = "{$stack}_{$service}";
    io()->error("Container {$name} is not ready after {$maxAttempts} retries.");

    throw new \RuntimeException("Container {$name} is not ready after {$maxAttempts} attempts.");
}

#[AsTask('wait-php-container')]
function waitPhpContainer(
    #[AsOption(description: 'Swarm service of the app, without the stack prefix')]
    string $service = 'php',
    #[AsOption(description: 'Stack name; defaults to STACK_NAME of the castor context')]
    string $stack = '',
): void {
    $stack = stackName($stack);

    io()->info("Waiting for container {$stack}_{$service} to start...");
    waitForReadyContainer($stack, $service);
    io()->success("PHP container is running!");
}

#[AsTask('wait-db-container')]
function waitDbContainer(
    #[AsOption(description: 'Swarm service of the database, without the stack prefix; also its host name')]
    string $service = 'db',
    #[AsOption(description: 'Swarm service of the app, without the stack prefix')]
    string $phpService = 'php',
    #[AsOption(description: 'Database port')]
    int $port = 5432,
    #[AsOption(description: 'Stack name; defaults to STACK_NAME of the castor context')]
    string $stack = '',
): void {
    $stack = stackName($stack);

    io()->info("Waiting for database container {$stack}_{$service} to be ready...");
    waitForReadyContainer($stack, $service);
    io()->success("Database container is ready!");

    $phpContainerId = runningContainerId($stack, $phpService);
    if ($phpContainerId === '') {
        io()->warning("PHP container not found, skipping DNS connectivity check.");
        return;
    }

    io()->info("Checking database DNS resolution from PHP container...");
    $dnsMaxAttempts = 30;
    for ($i = 0; $i < $dnsMaxAttempts; $i++) {
        $result = run(
            "docker exec {$phpContainerId} php -r \"@stream_socket_client('tcp://{$service}:{$port}', \\\$e, \\\$m, 2) ? exit(0) : exit(1);\"",
            context: context()->withAllowFailure()
        );
        if ($result->isSuccessful()) {
            io()->success("Database is reachable from PHP container!");
            return;
        }
        io()->warning("Database not yet reachable from PHP container, retrying... ({$i}/{$dnsMaxAttempts})");
        sleep(2);
    }

    throw new \RuntimeException("Database host '{$service}' is not reachable from PHP container after {$dnsMaxAttempts} attempts.");
}
