#!/usr/bin/env bash
# deploy.sh — despliegue idempotente de un sandbox de Alice.
#
#   ./scripts/deploy.sh juan --node vps-1          # instancia de instances/juan.env
#   ./scripts/deploy.sh --all --node vps-1         # todas las de instances/*.env
#   ./scripts/deploy.sh --node vps-1 --json        # modo manager (solo entorno)
#   ./scripts/deploy.sh --list                     # estado de cada instancia
#
# Idempotente: si nada cambió, `up -d` no recrea el contenedor.
#
# Topología: nodes/<nodo>.env (SANDBOX_TRANSPORT, SANDBOX_PORT,
# SANDBOX_PUBLIC_HOST, SANDBOX_NETWORK). Se selecciona con --node o NODE_ID;
# si no hay ninguno y existe exactamente un nodes/*.env, se usa ese.
#
# Precedencia: las variables del invocador (el Sandbox Manager) GANAN sobre
# instances/<instancia>.env. En modo manager no hace falta instancia: toma
# ALICE_JOB_ID, ALICE_USER_ID, ALICE_SANDBOX_ID y WS_TOKEN_SHA256 del entorno.
#
# Códigos de salida:
#   0  todo bien
#   1  fallo de ejecución (docker, readiness)
#   2  entrada inválida (INVALID_INPUT)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DRY_RUN=0
JSON=0
ACTION="deploy"
WAIT_READY=1
READY_TIMEOUT=90
NODE_FLAG=""
TARGETS=()
RESULTS=()
FAILED=0
ENV_MODE=0
SEEN_IDS=""
node_file=""

# --json se detecta antes de parsear: un error temprano también debe ser JSON.
for arg in "$@"; do
  if [ "$arg" = "--json" ]; then JSON=1; fi
done

log() {
  if [ "$JSON" -eq 1 ]; then printf '%s\n' "$*" >&2; else printf '%s\n' "$*"; fi
}

warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

json_escape() {
  local s="${1:-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# Un INVALID_INPUT sale por stdout en modo --json (el manager parsea stdout)
# y por stderr en modo humano. Siempre exit 2: input inválido, no reintentable.
invalid() {
  local msg="${1:-entrada inválida}"
  if [ "$JSON" -eq 1 ]; then
    printf '{"ok":false,"code":"INVALID_INPUT","message":"%s"}\n' "$(json_escape "$msg")"
  else
    printf 'INVALID_INPUT: %s\n' "$msg" >&2
  fi
  exit 2
}

usage() {
  cat <<'EOF'
Uso: deploy.sh [<instancia>... | --all | --list] [opciones]

Opciones:
  --node <id>          Nodo de nodes/<id>.env. Gana sobre NODE_ID.
  --json               Salida JSON por stdout; logs y avisos por stderr.
  --dry-run            No ejecuta docker; imprime lo que haría.
  --no-wait-ready      No espera a /readyz tras `up -d`.
  --ready-timeout <s>  Timeout de /readyz en segundos (default 90).
  -h, --help           Esta ayuda.

Modo manager (sin <instancia>): toma ALICE_JOB_ID, ALICE_USER_ID,
ALICE_SANDBOX_ID y WS_TOKEN_SHA256 del entorno; esas variables GANAN sobre
instances/*.env. Sin instancia ni ALICE_SANDBOX_ID: error de uso.
EOF
}

need_value() {
  local flag="$1" value="${2:-}"
  if [ -z "$value" ]; then
    invalid "$flag requiere un valor"
  fi
  case "$value" in
    -*) invalid "$flag requiere un valor (recibido: $value)" ;;
  esac
}

while [ "$#" -gt 0 ]; do
  arg="$1"
  case "$arg" in
    --dry-run) DRY_RUN=1; shift ;;
    --json)    JSON=1; shift ;;
    --all)     ACTION="all"; shift ;;
    --list)    ACTION="list"; shift ;;
    --node)
      need_value "$arg" "${2:-}"
      NODE_FLAG="$2"; shift 2 ;;
    --node=*)
      NODE_FLAG="${arg#*=}"
      [ -n "$NODE_FLAG" ] || invalid "--node requiere un id"
      case "$NODE_FLAG" in -*) invalid "--node requiere un id" ;; esac
      shift ;;
    --no-wait-ready) WAIT_READY=0; shift ;;
    --ready-timeout)
      need_value "$arg" "${2:-}"
      READY_TIMEOUT="$2"; shift 2 ;;
    --ready-timeout=*)
      READY_TIMEOUT="${arg#*=}"
      shift ;;
    -h|--help) usage; exit 0 ;;
    -*) invalid "flag desconocida: $arg" ;;
    *)  TARGETS+=("$arg"); shift ;;
  esac
done

case "$READY_TIMEOUT" in
  ''|0*|*[!0-9]*) invalid "--ready-timeout debe ser un entero positivo" ;;
esac
[ "$READY_TIMEOUT" -gt 0 ] || invalid "--ready-timeout debe ser un entero positivo"

if [ "$ACTION" = "list" ] && [ "$JSON" -eq 1 ]; then
  invalid "--json no se combina con --list"
fi

# El manager exporta estas variables antes de invocar deploy.sh. Se capturan
# aquí para re-aplicarlas DESPUÉS de cargar instances/*.env: el invocador gana.
_INV_JOB="${ALICE_JOB_ID:-}"
_INV_USER="${ALICE_USER_ID:-}"
_INV_SANDBOX="${ALICE_SANDBOX_ID:-}"
_INV_HASH="${WS_TOKEN_SHA256:-}"
_INV_TAG="${LETTA_TAG:-}"
_INV_LITELLM_URL="${LITELLM_BASE_URL:-}"
_INV_LITELLM_KEY="${LITELLM_API_KEY:-}"
_INV_USER_NAME="${USER_NAME:-}"

apply_invoker() {
  if [ -n "$_INV_JOB" ]; then export ALICE_JOB_ID="$_INV_JOB"; fi
  if [ -n "$_INV_USER" ]; then export ALICE_USER_ID="$_INV_USER"; fi
  if [ -n "$_INV_SANDBOX" ]; then export ALICE_SANDBOX_ID="$_INV_SANDBOX"; fi
  if [ -n "$_INV_HASH" ]; then export WS_TOKEN_SHA256="$_INV_HASH"; fi
  if [ -n "$_INV_TAG" ]; then export LETTA_TAG="$_INV_TAG"; fi
  if [ -n "$_INV_LITELLM_URL" ]; then export LITELLM_BASE_URL="$_INV_LITELLM_URL"; fi
  if [ -n "$_INV_LITELLM_KEY" ]; then export LITELLM_API_KEY="$_INV_LITELLM_KEY"; fi
  if [ -n "$_INV_USER_NAME" ]; then export USER_NAME="$_INV_USER_NAME"; fi
  return 0
}

read_env() {
  local file="$1" name="$2"
  (
    set -a
    # shellcheck disable=SC1090
    . "$file" >/dev/null 2>&1 || true
    printf '%s' "${!name:-}"
  )
}

# Lista de instancias desplegables: instances/*.env excluyendo las _plantilla.
list_instances() {
  local f
  for f in instances/*.env; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in _*) continue ;; esac
    basename "$f" .env
  done
}

node_list() {
  local f list=""
  for f in nodes/*.env; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in _*) continue ;; esac
    list+="${list:+, }$(basename "$f" .env)"
  done
  printf '%s' "$list"
}

# --node gana sobre NODE_ID. Sin ninguno: exactamente un nodes/*.env (con
# aviso); 0 o >=2 es INVALID_INPUT.
select_node() {
  local -a files=()
  local f id

  for f in nodes/*.env; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in _*) continue ;; esac
    files+=("$f")
  done

  if [ -n "${NODE_ID:-}" ] && [ -n "$NODE_FLAG" ] && [ "$NODE_ID" != "$NODE_FLAG" ]; then
    invalid "NODE_ID='$NODE_ID' y --node '$NODE_FLAG' no coinciden"
  fi

  id="${NODE_FLAG:-${NODE_ID:-}}"
  if [ -z "$id" ]; then
    case "${#files[@]}" in
      0)
        invalid "no hay nodes/*.env; crea nodes/<nodo>.env (ver nodes/_ejemplo.env)"
        ;;
      1)
        node_file="${files[0]}"
        id="$(basename "$node_file" .env)"
        warn "sin --node ni NODE_ID: usando el único nodo disponible '$id'"
        ;;
      *)
        invalid "hay varios nodos ($(node_list)); usa --node <nodo>"
        ;;
    esac
  else
    node_file="nodes/$id.env"
    if [ ! -f "$node_file" ]; then
      invalid "nodo '$id' no existe; válidos: $(node_list)"
    fi
  fi

  if ! bash -n "$node_file" 2>/dev/null; then
    invalid "$node_file: sintaxis inválida"
  fi

  # Cargar la topología. set -a para que docker compose también la vea.
  set -a
  # shellcheck disable=SC1090
  . "$node_file"
  set +a
}

validate_topology() {
  case "${SANDBOX_TRANSPORT:-}" in
    ws|wss) ;;
    "")
      invalid "falta SANDBOX_TRANSPORT en $node_file (ws o wss)"
      ;;
    *)
      invalid "SANDBOX_TRANSPORT debe ser ws o wss (recibido: ${SANDBOX_TRANSPORT})"
      ;;
  esac

  if [ -z "${SANDBOX_PORT:-}" ]; then
    if [ "$SANDBOX_TRANSPORT" = "wss" ]; then SANDBOX_PORT=443; else SANDBOX_PORT=4500; fi
  fi
  case "$SANDBOX_PORT" in
    ''|0*|*[!0-9]*) invalid "SANDBOX_PORT debe ser un entero (recibido: $SANDBOX_PORT)" ;;
  esac
  if [ "${#SANDBOX_PORT}" -gt 5 ]; then
    invalid "SANDBOX_PORT fuera de rango (1-65535): $SANDBOX_PORT"
  fi
  if [ "$SANDBOX_PORT" -lt 1 ] || [ "$SANDBOX_PORT" -gt 65535 ]; then
    invalid "SANDBOX_PORT fuera de rango (1-65535): $SANDBOX_PORT"
  fi

  SANDBOX_PUBLIC_HOST="${SANDBOX_PUBLIC_HOST:-}"
  if [ "$SANDBOX_TRANSPORT" = "wss" ] && [ -z "$SANDBOX_PUBLIC_HOST" ]; then
    invalid "SANDBOX_PUBLIC_HOST es obligatorio con SANDBOX_TRANSPORT=wss (un túnel sin hostname no es alcanzable)"
  fi
  if [ "$SANDBOX_TRANSPORT" = "ws" ] && [ -n "$SANDBOX_PUBLIC_HOST" ]; then
    warn "SANDBOX_PUBLIC_HOST='$SANDBOX_PUBLIC_HOST' con SANDBOX_TRANSPORT=ws: es legal (p. ej. LB interno), pero revisa que sea intencional"
  fi

  SANDBOX_NETWORK="${SANDBOX_NETWORK:-sandboxes}"
  export SANDBOX_TRANSPORT SANDBOX_PORT SANDBOX_PUBLIC_HOST SANDBOX_NETWORK
}

# Carga un instances/*.env y vuelve a aplicar el entorno del invocador.
load_instance() {
  local file="$1"
  if [ ! -f "$file" ]; then
    invalid "no existe $file"
  fi
  set -a
  # shellcheck disable=SC1090
  . "$file"
  set +a
  apply_invoker
}

# Valida la instancia efectiva (archivo + entorno ya fusionados).
validate_instance() {
  local sid="${ALICE_SANDBOX_ID:-}"
  if [ -z "$sid" ]; then
    invalid "falta ALICE_SANDBOX_ID (id único de la fila containers)"
  fi
  case "$sid" in
    -*) invalid "ALICE_SANDBOX_ID inválido ('$sid'): no puede empezar por '-'" ;;
    *[!A-Za-z0-9_.-]*) invalid "ALICE_SANDBOX_ID inválido ('$sid'): solo [A-Za-z0-9_.-]" ;;
  esac

  if [ -z "${ALICE_JOB_ID:-}" ]; then
    invalid "falta ALICE_JOB_ID (label alice.jobId)"
  fi
  if [ -z "${ALICE_USER_ID:-}" ]; then
    invalid "falta ALICE_USER_ID (label alice.userId)"
  fi

  local hash="${WS_TOKEN_SHA256:-}"
  if [[ ! "$hash" =~ ^[0-9a-fA-F]{64}$ ]]; then
    invalid "WS_TOKEN_SHA256 debe ser 64 hex (SHA-256 del capability token)"
  fi
  export WS_TOKEN_SHA256="${hash,,}"

  local tag="${LETTA_TAG:-}"
  if [ -z "$tag" ]; then
    invalid "falta LETTA_TAG"
  fi
  if [ "${tag,,}" = "latest" ]; then
    invalid "LETTA_TAG no puede ser 'latest' (sin rollback)"
  fi

  if [ -z "${LITELLM_BASE_URL:-}" ]; then
    invalid "falta LITELLM_BASE_URL"
  fi
  if [ -z "${LITELLM_API_KEY:-}" ]; then
    invalid "falta LITELLM_API_KEY"
  fi
}

# Valida todas las instancias antes de tocar docker: no queremos desplegar
# media flota y fallar a la mitad por un input inválido.
prepare_targets() {
  local t sid
  SEEN_IDS=""
  for t in "${TARGETS[@]}"; do
    load_instance "instances/$t.env"
    validate_instance
    sid="${ALICE_SANDBOX_ID,,}"
    case " $SEEN_IDS " in
      *" $sid "*) invalid "ALICE_SANDBOX_ID '$ALICE_SANDBOX_ID' repetido; container_name debe ser único por sandbox" ;;
    esac
    SEEN_IDS+=" $sid"
  done
}

add_success() {
  local sid="$1" cname="$2" host="$3" cid="$4"
  RESULTS+=("$(printf '{"ok":true,"sandboxId":"%s","containerName":"%s","internalHost":"%s","port":%s,"transport":"%s","containerId":"%s"}' \
    "$(json_escape "$sid")" "$(json_escape "$cname")" "$(json_escape "$host")" \
    "$SANDBOX_PORT" "$SANDBOX_TRANSPORT" "$(json_escape "$cid")")")
}

add_failure() {
  local sid="$1" cname="$2" code="$3" msg="$4" cid="$5"
  FAILED=1
  RESULTS+=("$(printf '{"ok":false,"sandboxId":"%s","containerName":"%s","code":"%s","message":"%s","containerId":"%s"}' \
    "$(json_escape "$sid")" "$(json_escape "$cname")" "$(json_escape "$code")" \
    "$(json_escape "$msg")" "$(json_escape "$cid")")")
}

docker_container_id() {
  local container="$1" id=""
  if [ "$DRY_RUN" -eq 0 ]; then
    id="$("$DOCKER" inspect -f '{{.Id}}' "$container" 2>/dev/null || true)"
  fi
  printf '%s' "${id:-$container}"
}

ready_check() {
  local container="$1"
  if [ -n "${READY_CHECK_CMD:-}" ]; then
    # Comando inyectable para pruebas o si la imagen no trae node. Se ejecuta
    # en el host y recibe DOCKER y CONTAINER_NAME en el entorno.
    DOCKER="$DOCKER" CONTAINER_NAME="$container" bash -c "$READY_CHECK_CMD" >/dev/null 2>&1
  else
    # /readyz dentro del contenedor: la imagen garantiza node (no curl/wget).
    "$DOCKER" exec "$container" node -e "fetch('http://127.0.0.1:4500/readyz',{signal:AbortSignal.timeout(3000)}).then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" >/dev/null 2>&1
  fi
}

wait_ready() {
  local container="$1"
  local deadline=$((SECONDS + READY_TIMEOUT))
  while :; do
    if ready_check "$container"; then return 0; fi
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 1
  done
}

deploy_one() {
  local sandbox_id="$1" envfile="$2"
  local container="alice-${sandbox_id}"
  local cid
  local -a compose_args=(compose -p "alice-${sandbox_id}" --env-file "$node_file")
  if [ -n "$envfile" ]; then
    compose_args+=(--env-file "$envfile")
  fi
  compose_args+=(up -d --remove-orphans)

  log "==> ${sandbox_id}${envfile:+ ($envfile)}"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "  [dry-run] $DOCKER ${compose_args[*]}"
  else
    if [ "$JSON" -eq 1 ]; then
      if ! "$DOCKER" "${compose_args[@]}" 1>&2; then
        add_failure "$sandbox_id" "$container" "DEPLOY_FAILED" "docker compose up falló" "$(docker_container_id "$container")"
        return 1
      fi
    else
      if ! "$DOCKER" "${compose_args[@]}"; then
        add_failure "$sandbox_id" "$container" "DEPLOY_FAILED" "docker compose up falló" "$(docker_container_id "$container")"
        return 1
      fi
    fi

    if [ "$WAIT_READY" -eq 1 ] && ! wait_ready "$container"; then
      add_failure "$sandbox_id" "$container" "READY_TIMEOUT" "sin respuesta en /readyz tras ${READY_TIMEOUT}s" "$(docker_container_id "$container")"
      return 1
    fi
  fi

  cid="$(docker_container_id "$container")"
  add_success "$sandbox_id" "$container" "${SANDBOX_PUBLIC_HOST:-$container}" "$cid"
  return 0
}

# Comando docker: real, o el doble de pruebas via DOCKER_BIN.
DOCKER="${DOCKER_BIN:-docker}"

case "$ACTION" in
  list)
    for local_user in $(list_instances); do
      sid="$(read_env "instances/$local_user.env" ALICE_SANDBOX_ID)"
      printf '%-20s ' "$local_user"
      "$DOCKER" ps --filter "label=alice.sandboxId=${sid}" \
        --format '{{.Status}}\t{{.Image}}' 2>/dev/null | head -1 || echo "(sin contenedor)"
    done
    exit 0
    ;;
  all)
    TARGETS=()
    for t in $(list_instances); do TARGETS+=("$t"); done
    [ "${#TARGETS[@]}" -gt 0 ] || invalid "no hay instances/*.env (excluyendo _plantilla)"
    ;;
  deploy)
    if [ "${#TARGETS[@]}" -eq 0 ]; then
      if [ -n "${ALICE_SANDBOX_ID:-}" ]; then
        ENV_MODE=1
      else
        invalid "uso: $0 <instancia>|--all|--list [--node <nodo>] [--json]"
      fi
    fi
    ;;
esac

select_node
validate_topology

if [ "$ENV_MODE" -eq 1 ]; then
  validate_instance
  deploy_one "$ALICE_SANDBOX_ID" "" || true
else
  prepare_targets
  for t in "${TARGETS[@]}"; do
    load_instance "instances/$t.env"
    validate_instance
    deploy_one "$ALICE_SANDBOX_ID" "instances/$t.env" || true
  done
fi

if [ "$JSON" -eq 1 ]; then
  results_json=""
  for r in "${RESULTS[@]}"; do
    results_json+="${results_json:+,}$r"
  done
  ok_bool=false
  if [ "$FAILED" -eq 0 ]; then ok_bool=true; fi
  printf '{"ok":%s,"results":[%s]}\n' "$ok_bool" "$results_json"
  [ "$FAILED" -eq 0 ] || exit 1
  exit 0
fi

if [ "$DRY_RUN" -eq 0 ]; then
  echo
  echo "==> Estado"
  for t in "${TARGETS[@]}"; do
    sid="$(read_env "instances/$t.env" ALICE_SANDBOX_ID)"
    "$DOCKER" ps --filter "label=alice.sandboxId=${sid}" --format "{{.Names}}\t{{.Status}}\t{{.Image}}" || true
  done
fi

[ "$FAILED" -eq 0 ] || exit 1
