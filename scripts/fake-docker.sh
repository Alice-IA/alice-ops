#!/usr/bin/env bash
# fake-docker.sh — doble de `docker` para probar deploy.sh sin Docker.
#
# Simula SOLO lo que deploy.sh invoca:
#   docker compose -p <proyecto> [--env-file ...] up -d --remove-orphans
#   docker compose -p <proyecto> ... down -v
#   docker inspect -f '{{.Id}}' <contenedor>
#   docker exec <contenedor> node -e '<fetch a /readyz>'
#   docker ps [-a] --filter label=... --format '{{json .}}'
#   docker ps --filter label=... --format '...'
#
# NO simula: creación real de contenedores, redes, volúmenes, healthchecks
# internos, ni la salida exacta de `compose`. Su objetivo es ejercitar la
# lógica de deploy.sh (args, env, códigos de salida), no Docker.
#
# Variables de control:
#   FAKE_DOCKER_LOG=<archivo>     registra cada invocación (args + env clave)
#   FAKE_DOCKER_COMPOSE_RC=<n>    exit de `compose` (default 0)
#   FAKE_DOCKER_EXEC_RC=<n>       exit de `exec` (default 0)
#   FAKE_DOCKER_INSPECT_EMPTY=1   `inspect` no imprime Id
#   FAKE_DOCKER_PS_JSON=<lineas>  salida de `ps --format '{{json .}}'`
set -u

if [ -n "${FAKE_DOCKER_LOG:-}" ]; then
  printf 'args: %s\n' "$*" >> "$FAKE_DOCKER_LOG"
  printf 'env: ALICE_JOB_ID=%s ALICE_USER_ID=%s ALICE_SANDBOX_ID=%s WS_TOKEN_SHA256=%s LETTA_TAG=%s USER_NAME=%s\n' \
    "${ALICE_JOB_ID:-}" "${ALICE_USER_ID:-}" "${ALICE_SANDBOX_ID:-}" \
    "${WS_TOKEN_SHA256:-}" "${LETTA_TAG:-}" "${USER_NAME:-}" >> "$FAKE_DOCKER_LOG"
fi

case "${1:-}" in
  compose)
    # `up -d` / `down -v`: eco a stdout; deploy.sh lo manda a stderr en --json.
    printf '[fake-docker] %s\n' "$*"
    exit "${FAKE_DOCKER_COMPOSE_RC:-0}"
    ;;
  inspect)
    if [ "${FAKE_DOCKER_INSPECT_EMPTY:-0}" = "1" ]; then
      exit 0
    fi
    last=""
    for last in "$@"; do :; done
    printf 'cid-%s\n' "$last"
    exit 0
    ;;
  exec)
    exit "${FAKE_DOCKER_EXEC_RC:-0}"
    ;;
  ps)
    if [ -n "${FAKE_DOCKER_PS_JSON:-}" ]; then
      printf '%s\n' "$FAKE_DOCKER_PS_JSON"
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
