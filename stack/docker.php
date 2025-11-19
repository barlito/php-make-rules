<?php

namespace Barlito\Castor;

use Castor\Attribute\AsTask;
use Castor\Exception\WaitFor\DockerContainerStateException;

use function Castor\capture;
use function Castor\io;
use function Castor\context;
use function Castor\wait_for_docker_container;
use function Castor\run;

//#[AsTask('wait-php-container')]
//function waitPhpContainer($loopCount = 0): void
//{
//    $context = context();
//    $STACK_NAME = $context->environment['STACK_NAME'];
//
//    try {
//        wait_for_docker_container(
//            containerName: '${STACK_NAME}_php',
////          portsToCheck: [80, 443],
//            message: "Waiting for Container {$STACK_NAME}_php to be ready...",
//            containerChecker: function ($containerId) {
//                io()->info(capture("docker exec $containerId bash -c 'getent hosts ytcg_db'", context: context()->withAllowFailure()));
//                return run("docker exec $containerId bash -c 'php bin/console dbal:run-sql -q \"SELECT 1\" 2>&1'", context: context()->withAllowFailure())->isSuccessful();
//            }
//        );
//    } catch (DockerContainerStateException $exception) {
//        if($loopCount > 60) {
//            throw $exception;
//        }
//
//        io()->info("Waiting for Container {$STACK_NAME}_php to be ready..." . $loopCount);
//        sleep(1);
//        waitNginxContainer($loopCount + 1);
//    }
//}


#[AsTask('wait-php-container')]
function waitPhpContainerSimple(int $attempt = 0): void
{
    $context = context();
    $STACK_NAME = $context->environment['STACK_NAME'];
    $containerName = "{$STACK_NAME}_php";
    $maxAttempts = 60;

    if ($attempt > 0) {
        io()->info("Retrying to check if container {$containerName} is running (Attempt {$attempt}/{$maxAttempts})...");
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

        io()->warning("Container {$containerName} is not yet running, retrying... ({$attempt}/{$maxAttempts})");
        sleep(1);
        waitPhpContainerSimple($attempt + 1);
    }
}




//#[AsTask('wait-php-container')]
//function waitPhpContainer(int $containerAttempt = 0): void
//{
//    $context = context();
//    $STACK_NAME = $context->environment['STACK_NAME'];
//    $containerName = "{$STACK_NAME}_php";
//    $maxAttempts = 60;
//
//    if ($containerAttempt > 0) {
//        io()->info("Retrying to check Container {$containerName} (Attempt {$containerAttempt}/{$maxAttempts})...");
//    } else {
//        io()->info("Waiting for Container {$containerName} to be ready...");
//    }
//
//    try {
//        wait_for_docker_container(
//            containerName: $containerName,
//            message: "Checking if {$containerName} is ready...",
//            containerChecker: function ($containerId) use ($maxAttempts) {
//                $databaseUrlCheck = run("docker exec $containerId sh -c 'grep -q ^DATABASE_URL= .env && echo found || echo not_found'",
//                    context: context()->withAllowFailure());
//                $hasDatabaseUrl = trim($databaseUrlCheck->getOutput()) === 'found';
//                if (!$hasDatabaseUrl) {
//                    io()->info("No DATABASE_URL found in .env. Skipping database readiness check.");
//                    return true;
//                }
//
//                io()->info("DATABASE_URL detected. Waiting for database to be ready...");
//                $attempt = 0;
//
//                while ($attempt < $maxAttempts) {
//                    try {
//                        $dbReady = run("docker exec $containerId php bin/console dbal:run-sql -q \"SELECT 1\"", context: context()->withAllowFailure());
//
//                        if ($dbReady->isSuccessful()) {
//                            io()->success("The database is now ready and reachable.");
//                            return true;
//                        }
//
//                        io()->warning("Still waiting for database to be ready... " . ($maxAttempts - $attempt) . " attempts left.");
//                        sleep(1);
//                        $attempt++;
//                    } catch (\Throwable $e) {
//                        io()->error("Error checking database readiness: " . $e->getMessage());
//                        return false;
//                    }
//                }
//
//                io()->error("The database is not up or not reachable after {$maxAttempts} attempts.");
//                return false;
//            }
//        );
//
//        io()->success("PHP app is ready!");
//    } catch (DockerContainerStateException $e) {
//        if ($containerAttempt >= $maxAttempts) {
//            io()->error("Container {$containerName} is not running after {$maxAttempts} retries.");
//            throw $e;
//        }
//
//        io()->warning("Container {$containerName} is not yet running, retrying... ({$containerAttempt}/{$maxAttempts})");
//        sleep(1);
//        waitPhpContainer($containerAttempt + 1);
//    }
//}


#[AsTask('wait-db-container')]
function waitDbContainer(int $attempt = 0): void
{
    $context = context();
    $STACK_NAME = $context->environment['STACK_NAME'];
    $dbContainer = "{$STACK_NAME}_db";
    $maxAttempts = 60;

    if ($attempt > 0) {
        io()->info("Retrying database container check (Attempt {$attempt}/{$maxAttempts})...");
    } else {
        io()->info("Waiting for database container {$dbContainer} to be ready...");
    }

    try {
        wait_for_docker_container(
            containerName: $dbContainer,
            message: "Checking if {$dbContainer} is running and healthy...",
        );
        io()->success("Database container is running and healthy!");
    } catch (DockerContainerStateException $e) {
        if ($attempt >= $maxAttempts) {
            io()->error("Database container {$dbContainer} is not ready after {$maxAttempts} retries.");
            throw $e;
        }
        io()->warning("Database container {$dbContainer} is not yet ready, retrying... ({$attempt}/{$maxAttempts})");
        sleep(1);
        waitDbContainer($attempt + 1);
    }
}
