#!/usr/bin/env bash
# Runs the castor task tests in a disposable php container (nothing is installed on the host)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

docker run --rm -v "$root:/repo:ro" php:8.4-cli bash -euc '
  apt-get update -qq && apt-get install -y -qq git >/dev/null
  curl -fsSL -o /usr/local/bin/castor https://github.com/jolicode/castor/releases/download/v1.9.1/castor.linux-amd64.phar
  echo "3312568da9a593ad7d3ef6548f05c12d994dbc7140634e401531dc8d7de41764  /usr/local/bin/castor" | sha256sum -c -
  chmod +x /usr/local/bin/castor
  bash /repo/tests/castor_inside.sh
'
