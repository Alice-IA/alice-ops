#!/usr/bin/env bash
# deploy.sh — despliegue idempotente de una o todas las instancias de Alice.
#
#   ./scripts/deploy.sh juan --node vps-1          # crea/actualiza la instancia juan
#   ./scripts/deploy.sh --all --node vps-1         # todas las de instances/*.env
#   ./scripts/deploy.sh --node vps-1 --json        # salida máquina-legible
#   ./scripts/deploy.sh --list                     # estado de cada instancia
#
# Idempotente: si nada cambió, `up -d` no recrea el contenedor.
#
# Topología: nodes/<nodo>.env (SANDBOX_TRANSPORT, SANDBOX_PORT,
# SANDBOX_PUBLIC_HOST, SANDBOX_NETWORK). Se selecciona con --node, o con
# NODE_ID; si no hay ninguno y existe exactamente un nodes/*.env, se usa ese.
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
node_file=""

# Detectar --json antes de parsear: un error temprano también debe ser JSON.
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

Variables de entorno:
  READY_CHECK_CMD      Comando de readiness ejecutado en el host. Recibe
                       DOCKER y CONTAINER_NAME. Default: docker exec <c>
                       node -e "fetch('http://127.0.0.1:4500/readyz')...".
                       Útil si la imagen no trae node (ver README).

Topología (nodes/<id>.env):
  SANDBOX_TRANSPORT=ws|wss     obligatoria
  SANDBOX_PORT=4500|443        default 4500 (ws) / 443 (wss)
  SANDBOX_PUBLIC_HOST=<host>   vacío = nombre del contenedor (solo ws)
  SANDBOX_NETWORK=sandboxes    opcional
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

# Lista de instancias desplegables: instances/*.env excluyendo los _plantilla.
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

# --node gana sobre NODE_ID. Si no hay ninguno: exactamente un nodes/*.env
# (con aviso por stderr); 0 o >=2 es INVALID_INPUT.
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

validate_targets() {
  local t f user hash tag sandbox_id sandbox_key seen_ids=""
  for t in "${TARGETS[@]}"; do
    f="instances/$t.env"
    [ -f "$f" ] || invalid "no existe $f"

    user="$(read_env "$f" USER_NAME)"
    [ -n "$user" ] || invalid "$f: falta USER_NAME"
    case "$user" in
      *[!A-Za-z0-9_.-]*|.*) invalid "$f: USER_NAME inválido ('$user')" ;;
    esac

    sandbox_id="$(read_env "$f" ALICE_SANDBOX_ID)"
    [ -n "$sandbox_id" ] || invalid "$f: falta ALICE_SANDBOX_ID (id único de la fila containers)"
    case "$sandbox_id" in
      *[!A-Za-z0-9_.-]*|.*|-*) invalid "$f: ALICE_SANDBOX_ID inválido ('$sandbox_id')" ;;
    esac
    # Docker compara container_name sin distinguir mayúsculas.
    sandbox_key="${sandbox_id,,}"
    case " $seen_ids " in
      *" $sandbox_key "*) invalid "$f: ALICE_SANDBOX_ID '$sandbox_id' repetido; container_name debe ser único por sandbox" ;;
    esac
    seen_ids+=" $sandbox_key"

    hash="$(read_env "$f" WS_TOKEN_SHA256)"
    if [[ ! "$hash" =~ ^[0-9a-fA-F]{64}$ ]]; then
      invalid "$f: WS_TOKEN_SHA256 debe ser 64 hex (SHA-256 del capability token)"
    fi

    tag="$(read_env "$f" LETTA_TAG)"
    [ -n "$tag" ] || invalid "$f: falta LETTA_TAG"
    if [ "${tag,,}" = "latest" ]; then
      invalid "$f: LETTA_TAG no puede ser 'latest' (sin rollback)"
    fi
  done
}

run_compose() {
  local user="$1" envfile="$2"
  if [ "$DRY_RUN" -eq 1 ]; then
    log "  [dry-run] $DOCKER compose -p alice-$user --env-file $node_file --env-file $envfile up -d --remove-orphans"
    return 0
  fi
  # En --json, todo lo que no sea el JSON final va a stderr.
  if [ "$JSON" -eq 1 ]; then
    "$DOCKER" compose -p "alice-$user" --env-file "$node_file" --env-file "$envfile" up -d --remove-orphans 1>&2
  else
    "$DOCKER" compose -p "alice-$user" --env-file "$node_file" --env-file "$envfile" up -d --remove-orphans
  fi
}

ready_check() {
  local container="$1"
  if [ -n "${READY_CHECK_CMD:-}" ]; then
    # Comando inyectable para pruebas o si la imagen no trae node. Se ejecuta
    # en el host y recibe DOCKER y CONTAINER_NAME en el entorno.
    DOCKER="$DOCKER" CONTAINER_NAME="$container" bash -c "$READY_CHECK_CMD" >/dev/null 2>&1
  else
    # /readyz dentro del contenedor: la imagen garantiza node (no curl/wget).
    # AbortSignal.timeout evita que un fetch colgado bloquee el poll.
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

docker_container_id() {
  local container="$1" id=""
  if [ "$DRY_RUN" -eq 0 ]; then
    id="$("$DOCKER" inspect -f '{{.Id}}' "$container" 2>/dev/null || true)"
  fi
  printf '%s' "${id:-$container}"
}

add_success() {
  local user="$1" endpoint="$2" cid="$3"
  RESULTS+=("$(printf '{"ok":true,"instance":"%s","containerId":"%s","internalHost":"%s","port":%s,"transport":"%s"}' \
    "$(json_escape "$user")" "$(json_escape "$cid")" "$(json_escape "$endpoint")" "$SANDBOX_PORT" "$SANDBOX_TRANSPORT")")
}

add_failure() {
  local user="$1" code="$2" msg="$3" cid="$4"
  FAILED=1
  RESULTS+=("$(printf '{"ok":false,"instance":"%s","code":"%s","message":"%s","containerId":"%s"}' \
    "$(json_escape "$user")" "$(json_escape "$code")" "$(json_escape "$msg")" "$(json_escape "$cid")")")
}

deploy_one() {
  local target="$1" envfile="instances/$1.env"
  local sandbox_id container endpoint cid

  sandbox_id="$(read_env "$envfile" ALICE_SANDBOX_ID)"
  container="alice-${sandbox_id}"

  # El .env de la instancia manda sobre el entorno del host: docker compose
  # interpola con prioridad el shell, y no queremos que un USER_NAME,
  # ALICE_SANDBOX_ID, WS_TOKEN_SHA256 o LITELLM_API_KEY global pise los de
  # esta instancia.
  export USER_NAME="$(read_env "$envfile" USER_NAME)"
  export ALICE_SANDBOX_ID="$sandbox_id"
  export LETTA_TAG="$(read_env "$envfile" LETTA_TAG)"
  export WS_TOKEN_SHA256="$(read_env "$envfile" WS_TOKEN_SHA256)"
  export LITELLM_BASE_URL="$(read_env "$envfile" LITELLM_BASE_URL)"
  export LITELLM_API_KEY="$(read_env "$envfile" LITELLM_API_KEY)"

  log "==> $target ($envfile)"

  if ! run_compose "$target" "$envfile"; then
    warn "$target: docker compose up falló"
    add_failure "$target" "DEPLOY_FAILED" "docker compose up falló" "$(docker_container_id "$container")"
    return 1
  fi

  if [ "$DRY_RUN" -eq 0 ] && [ "$WAIT_READY" -eq 1 ]; then
    if ! wait_ready "$container"; then
      warn "$target: READY_TIMEOUT (sin /readyz en ${READY_TIMEOUT}s)"
      add_failure "$target" "READY_TIMEOUT" "sin respuesta en /readyz tras ${READY_TIMEOUT}s" "$(docker_container_id "$container")"
      return 1
    fi
  fi

  endpoint="${SANDBOX_PUBLIC_HOST:-$container}"
  cid="$(docker_container_id "$container")"
  add_success "$target" "$endpoint" "$cid"
  [ "$JSON" -eq 1 ] || log "    endpoint ${SANDBOX_TRANSPORT}://${endpoint}:${SANDBOX_PORT}"
  return 0
}

# Comando docker: real, o el doble de pruebas via DOCKER_BIN.
DOCKER="${DOCKER_BIN:-docker}"

case "$ACTION" in
  list)
    [ "$JSON" -eq 0 ] || invalid "--json no se combina con --list"
    for local_user in $(list_instances); do
      printf '%-20s ' "$local_user"
      label_user="$(read_env "instances/$local_user.env" USER_NAME)"
      "$DOCKER" ps --filter "label=alice.instance=${label_user:-$local_user}" \
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
    [ "${#TARGETS[@]}" -gt 0 ] || invalid "uso: $0 <instancia>|--all|--list [--node <nodo>] [--json]"
    ;;
esac

select_node
validate_topology
validate_targets

# Evita desplegar media flota y fallar a la mitad por un input inválido.
for t in "${TARGETS[@]}"; do
  deploy_one "$t" || true
done

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
    label_user="$(read_env "instances/$t.env" USER_NAME)"
    "$DOCKER" ps --filter "label=alice.instance=${label_user:-$t}" --format "{{.Names}}\t{{.Status}}\t{{.Image}}" || true
  done
fi

[ "$FAILED" -eq 0 ] || exit 1
