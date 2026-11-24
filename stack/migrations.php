<?php

declare(strict_types=1);

namespace Barlito\Castor;

use Castor\Attribute\AsArgument;
use Castor\Attribute\AsOption;
use Castor\Attribute\AsTask;

use function Castor\capture;
use function Castor\context;
use function Castor\run;

/**
 * @param list<string> $files
 *
 * @return list<string>
 */
function migrationVersions(array $files): array
{
    $versions = [];
    foreach ($files as $file) {
        $name = basename($file, '.php');
        if (1 === preg_match('/^Version\w+$/', $name)) {
            $versions[] = $name;
        }
    }
    sort($versions);

    return $versions;
}

/**
 * Fully qualified names of the migrations to revert, newest first: exactly those missing from the target tag.
 *
 * @param list<string> $current migration versions of the working tree
 * @param list<string> $target  migration versions of the target tag
 *
 * @return list<string>
 */
function migrationsToRevert(array $current, array $target, string $namespace): array
{
    $added = array_values(array_diff($current, $target));
    rsort($added);

    return array_map(static fn (string $version): string => $namespace . '\\' . $version, $added);
}

// The migrations go to --output: a file keeps it clear of castor's own log lines on stdout
#[AsTask('migrations-rollback-target', description: 'List the Doctrine migrations to revert when rolling back to a tag, newest first (empty if none)')]
function migrationsRollbackTarget(
    #[AsArgument(description: 'Git tag or revision to roll back to, e.g. v1.2.0')]
    string $tag,
    #[AsOption(description: 'Migrations directory')]
    string $dir = 'migrations',
    #[AsOption(description: 'Migrations namespace')]
    string $namespace = 'DoctrineMigrations',
    #[AsOption(description: 'File receiving one migration per line, left empty when none has to be reverted')]
    string $output = 'php://stdout',
): void {
    $quiet = context()->withQuiet();

    // An unknown tag must fail: reading it as "no migration" would skip a needed revert
    if (!run(['git', 'rev-parse', '--verify', '--quiet', $tag . '^{commit}'], context: $quiet->withAllowFailure())->isSuccessful()) {
        fwrite(\STDERR, "Revision {$tag} not found: fetch the tags and the full history (fetch-depth: 0)\n");

        exit(1);
    }

    $target = migrationVersions(array_filter(explode("\n", capture(
        ['git', 'ls-tree', '-r', '--name-only', $tag, '--', rtrim($dir, '/') . '/'],
        context: $quiet,
    ))));
    $current = migrationVersions(glob(rtrim(context()->workingDirectory, '/') . '/' . rtrim($dir, '/') . '/Version*.php') ?: []);

    $added = array_diff($current, $target);
    if ([] !== $added) {
        fwrite(\STDERR, "Migrations added since {$tag}: " . implode(', ', $added) . "\n");
    }

    $revert = migrationsToRevert($current, $target, $namespace);
    file_put_contents($output, [] === $revert ? '' : implode("\n", $revert) . "\n");
}
