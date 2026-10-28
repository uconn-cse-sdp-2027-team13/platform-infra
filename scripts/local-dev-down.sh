#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/compose/docker-compose.yml"

docker compose --project-directory "$REPO_ROOT" --file "$COMPOSE_FILE" down "$@"
