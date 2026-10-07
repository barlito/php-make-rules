<?php

namespace Barlito\Castor;

use Castor\Attribute\AsArgument;
use Castor\Attribute\AsOption;
use Castor\Attribute\AsTask;

use function Castor\capture;
use function Castor\context;
use function Castor\io;

const SWARM_PENDING_UPDATE_STATES = ['updating', 'rollback_started'];

/**
 * @return array<string, mixed>
 */
function dockerInspect(string ...$args): array
{
    $json = capture(['docker', ...$args, '--format', '{{json .}}'], context: context()->withQuiet());

    return json_decode($json, true, flags: \JSON_THROW_ON_ERROR);
}

function imageMatches(string $image, string $expected): bool
{
    // Swarm pins the digest: "repo:tag@sha256:…"
    return $image === $expected || str_starts_with($image, $expected . '@');
}

function withoutDigest(string $image): string
{
    return explode('@', $image, 2)[0];
}

function updateState(string $service): string
{
    return (string) (dockerInspect('service', 'inspect', $service)['UpdateStatus']['State'] ?? '');
}

/**
 * @return array{ok: bool, tasks: list<string>, report: string}
 */
function runningTasksState(string $service, string $expected): array
{
    $spec = dockerInspect('service', 'inspect', $service)['Spec'];
    $replicas = $spec['Mode']['Replicated']['Replicas'] ?? null;

    $ids = array_filter(explode("\n", trim(capture(
        ['docker', 'service', 'ps', $service, '--filter', 'desired-state=running', '-q', '--no-trunc'],
        context: context()->withQuiet(),
    ))));
    sort($ids);

    $ok = [] !== $ids && (null === $replicas || \count($ids) === $replicas);
    $report = [];
    foreach ($ids as $id) {
        $task = dockerInspect('inspect', $id);
        $state = $task['Status']['State'] ?? 'unknown';
        $image = $task['Spec']['ContainerSpec']['Image'] ?? '';
        $containerId = $task['Status']['ContainerStatus']['ContainerID'] ?? '';
        // Only readable on the node running the container (single-node Swarm here)
        $health = '' === $containerId ? 'unknown' : trim(capture(
            ['docker', 'inspect', $containerId, '--format', '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}'],
            context: context()->withQuiet()->withAllowFailure(),
        ));

        $report[] = \sprintf('%s: %s %s, health %s', substr($id, 0, 12), $state, withoutDigest($image), $health ?: 'unknown');
        if ('running' !== $state || !imageMatches($image, $expected) || !\in_array($health, ['healthy', 'none'], true)) {
            $ok = false;
        }
    }

    $summary = \sprintf('%d/%s task(s)', \count($ids), $replicas ?? 'global');

    return ['ok' => $ok, 'tasks' => $ids, 'report' => $summary . ([] === $report ? '' : ' — ' . implode('; ', $report))];
}

// `docker service update` / `stack deploy` exit 0 even after a rollback: fail unless the service really runs $image, healthy
#[AsTask('assert-deployed', description: 'Fail unless a Swarm service runs the expected image, healthy and stable')]
function assertDeployed(
    #[AsArgument(description: 'Swarm service, e.g. ytcg_php')]
    string $service,
    #[AsArgument(description: 'Expected image, e.g. barlito/youl-tcg:v1.10.1')]
    string $image,
    #[AsOption(description: 'Seconds to wait for convergence and health')]
    int $timeout = 180,
    #[AsOption(description: 'Seconds the same healthy tasks must survive')]
    int $settle = 10,
): void {
    $deadline = time() + $timeout;

    while (\in_array($state = updateState($service), SWARM_PENDING_UPDATE_STATES, true) && time() < $deadline) {
        io()->writeln("… {$service} update state: {$state}");
        sleep(5);
    }

    $specImage = dockerInspect('service', 'inspect', $service)['Spec']['TaskTemplate']['ContainerSpec']['Image'];
    if (!imageMatches($specImage, $image)) {
        deployCheckFailed("{$service} runs " . withoutDigest($specImage) . " instead of {$image} (update state: " . ($state ?: 'none') . ')');
    }
    if (str_starts_with($state, 'rollback_') || \in_array($state, ['paused', 'updating'], true)) {
        deployCheckFailed("{$service} update state: {$state}");
    }

    $stableTasks = null;
    while (true) {
        $current = runningTasksState($service, $image);
        if ($current['ok']) {
            if ($stableTasks === $current['tasks']) {
                break;
            }
            $stableTasks = $current['tasks'];
            sleep($settle);

            continue;
        }

        $stableTasks = null;
        if (time() >= $deadline) {
            deployCheckFailed("{$service} not healthy on {$image}: {$current['report']}");
        }
        io()->writeln("… {$service}: {$current['report']}");
        sleep(5);
    }

    io()->success("{$service} runs {$image}: {$current['report']} (update state: " . ($state ?: 'none') . ')');
}

function deployCheckFailed(string $message): never
{
    io()->error($message);

    exit(1);
}
