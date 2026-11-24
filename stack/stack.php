<?php

namespace Barlito\Castor;

use Castor\Attribute\AsTask;

use Exception;
use function Castor\io;

const STACK_NAME_PLACEHOLDER = 'starter';
const STACK_NAME_FILES = [
    'castor.php',
    'Makefile',
    'docker-compose.yml',
];
// Present in projects created from php-starter; skipped when missing
const STACK_NAME_OPTIONAL_FILES = [
    'docker-compose-ci.yml',
    'docker-compose-prod.yml',
    '.github/workflows/release.yaml',
    '.github/workflows/deploy.yaml',
    '.github/workflows/rollback.yaml',
];


/**
 * @throws Exception
 */
#[AsTask('set-stack-name')]
function setStackName(
    string $stackName,
): void
{
    $optionalFiles = array_filter(STACK_NAME_OPTIONAL_FILES, 'file_exists');

    replaceStringInFiles(STACK_NAME_PLACEHOLDER, $stackName, [...STACK_NAME_FILES, ...$optionalFiles]);

    io()->success('Stack name has been set.');
}

/**
 * @throws Exception
 */
function replaceStringInFiles(string $placeholder, string $replacement, array $files): void
{
    foreach ($files as $filename) {
        if (!file_exists($filename)) {
            throw new Exception("Le fichier $filename n'existe pas.");
        }

        $content = file_get_contents($filename);
        if ($content === false) {
            throw new Exception("Impossible de lire le contenu du fichier $filename.");
        }

        $newContent = str_replace($placeholder, $replacement, $content);

        if (file_put_contents($filename, $newContent) === false) {
            throw new Exception("Impossible d'écrire dans le fichier $filename.");
        }
    }
}