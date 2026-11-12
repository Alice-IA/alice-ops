#!/usr/bin/env bash
# tests/deploy-test.sh — contrato de deploy.sh sin Docker real.
#
# Uso: bash tests/deploy-test.sh
# Cubre: selección de nodo, transporte ws/wss, validaciones de entrada
# (ALICE_JOB_ID/USER_ID/SANDBOX_ID, hash, tag), precedencia de entorno del
# manager sobre instances/*.env, readiness, forma del JSON (results[] con
# sandboxId/containerName) y el contrato estático de docker-compose.yml.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
TMPDIRS=()
REPO=""
HASH_DEFAULT="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
HASH_UPPER="0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF"

cleanup() {
  local d
  for d in ${TMPDIRS[@]+"${TMPDIRS[@]}"}; do
    rm -rf "$d"
  done
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$*"; }

assert_eq() { # got want msg
  if [ "$1" = "$2" ]; then
    pass "$3"
  else
    fail "$3 (esperado '$2', obtenido '$1')"
  fi
}

assert_contains() { # haystack needle msg
  case "$1" in
    *"$2"*) pass "$3" ;;
    *) fail "$3 (no contiene '$2'; salida: $1)" ;;
  esac
}

assert_not_contains() { # haystack needle msg
  case "$1" in
    *"$2"*) fail "$3 (contiene '$2'; salida: $1)" ;;
    *) pass "$3" ;;
  esac
}

assert_json_valid() { # body msg
  if ! command -v node >/dev/null 2>&1; then
    return 0
  fi
  if printf '%s' "$1" | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>{JSON.parse(s)})' 2>/dev/null; then
    pass "$2"
  else
    fail "$2 (JSON inválido: $1)"
  fi
}

assert_file_absent() { # path msg
  if [ -e "$1" ]; then
    fail "$2 (existe $1)"
  else
    pass "$2"
  fi
}

assert_has_line() { # file regex msg
  if grep -Eq "$2" "$1"; then
    pass "$3"
  else
    fail "$3 (no hay línea /$2/ en $1)"
  fi
}

assert_no_line() { # file regex msg
  if grep -Eq "$2" "$1"; then
    fail "$3 (hay línea /$2/ en $1)"
  else
    pass "$3"
  fi
}

make_repo() {
  local d
  d="$(mktemp -d "${TMPDIR:-/tmp}/alice-ops-test.XXXXXX")"
  mkdir -p "$d/scripts" "$d/instances" "$d/nodes"
  cp "$ROOT/scripts/deploy.sh" "$d/scripts/deploy.sh"
  cp "$ROOT/scripts/fake-docker.sh" "$d/scripts/fake-docker.sh"
  TMPDIRS+=("$d")
  REPO="$d"
}

write_instance() { # dir name [sandbox_id] [hash] [tag] [job] [user]
  local d="$1" name="$2"
  local sid="${3-sandbox-$name}"
  local hash="${4-$HASH_DEFAULT}"
  local tag="${5-0.34.39}"
  local job="${6-job-$name}"
  local usr="${7-user-$name}"
  cat > "$d/instances/$name.env" <<EOF
USER_NAME=$name
ALICE_JOB_ID=$job
ALICE_USER_ID=$usr
ALICE_SANDBOX_ID=$sid
LETTA_TAG=$tag
WS_TOKEN_SHA256=$hash
LITELLM_BASE_URL=http://litellm:4000
LITELLM_API_KEY=sk-test
EOF
}

write_node() { # dir name transport [port] [public_host]
  local d="$1" name="$2" transport="$3" port="${4-}" host="${5-}"
  {
    printf 'SANDBOX_TRANSPORT=%s\n' "$transport"
    if [ -n "$port" ]; then printf 'SANDBOX_PORT=%s\n' "$port"; fi
    printf 'SANDBOX_PUBLIC_HOST=%s\n' "$host"
  } > "$d/nodes/$name.env"
}

make_failing_docker() { # dir
  cat > "$1/scripts/fail-docker.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  compose) echo "fallo simulado de docker" >&2; exit 7 ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$1/scripts/fail-docker.sh"
}

run_deploy() { # dir args...
  local d="$1"
  shift
  ( cd "$d" && DOCKER_BIN="$d/scripts/fake-docker.sh" bash "$d/scripts/deploy.sh" "$@" )
}

# ---------------------------------------------------------------------------
# Selección de nodo
# ---------------------------------------------------------------------------

test_cero_nodos() {
  make_repo
  write_instance "$REPO" juan
  local out rc
  out="$(run_deploy "$REPO" juan --json --dry-run 2>"$REPO/err")"
  rc=$?
  assert_eq "$rc" 2 "0 nodos => exit 2"
  assert_contains "$out" '"code":"INVALID_INPUT"' "0 nodos devuelve INVALID_INPUT"
  assert_contains "$out" 'nodes/*.env' "el mensaje explica que falta la topología"
}

test_un_nodo_auto_avisa() {
  make_repo
  write_instance "$REPO" juan
  write_node "$REPO" vps ws 4500 ""
  local out err rc
  out="$(run_deploy "$REPO" juan --json --dry-run 2>"$REPO/err")"
  rc=$?
  err="$(cat "$REPO/err")"
  assert_eq "$rc" 0 "un único nodo se usa sin --node"
  assert_contains "$err" "único nodo disponible 'vps'" "aviso por stderr del nodo inferido"
  assert_contains "$out" '"ok":true' "JSON ok"
  assert_contains "$out" '"sandboxId":"sandbox-juan"' "results[] trae sandboxId"
  assert_contains "$out" '"containerName":"alice-sandbox-juan"' "results[] trae containerName"
  assert_contains "$out" '"internalHost":"alice-sandbox-juan"' "internalHost = alice-<ALICE_SANDBOX_ID>"
  assert_contains "$out" '"port":4500' "puerto 4500 para ws"
  assert_contains "$out" '"transport":"ws"' "transport ws"
  assert_not_contains "$out" 'fake-docker' "stdout limpio: los logs van a stderr"
  assert_json_valid "$out" "JSON de deploy válido"
}

test_dos_nodos_sin_flag() {
  make_repo
  write_instance "$REPO" juan
  write_node "$REPO" a ws 4500 ""
  write_node "$REPO" b wss 443 tunnel.example.com
  local out rc
  out="$(run_deploy "$REPO" juan --json --dry-run 2>"$REPO/err")"
  rc=$?
  assert_eq "$rc" 2 "2 nodos sin --node => INVALID_INPUT"
  assert_contains "$out" 'varios nodos' "el mensaje pide elegir nodo"
  assert_contains "$out" 'a, b' "el mensaje lista los nodos válidos"
}

test_dos_nodos_con_flag() {
  make_repo
  write_instance "$REPO" juan
  write_node "$REPO" a ws 4500 ""
  write_node "$REPO" b wss 443 tunnel.example.com
  local out rc
  out="$(run_deploy "$REPO" juan --node b --json --dry-run 2>"$REPO/err")"
  rc=$?
  assert_eq "$rc" 0 "--node b selecciona la topología wss"
  assert_contains "$out" '"transport":"wss"' "transport wss"
  assert_contains "$out" '"internalHost":"tunnel.example.com"' "internalHost = SANDBOX_PUBLIC_HOST"
  assert_contains "$out" '"port":443' "puerto 443"
}

test_flag_y_env_distintos() {
  make_repo
  write_instance "$REPO" juan
  write_node "$REPO" a ws 4500 ""
  write_node "$REPO" b wss 443 tunnel.example.com
  local out rc
  out="$(cd "$REPO" && NODE_ID=a DOCKER_BIN="$REPO/scripts/fake-docker.sh" \
    bash "$REPO/scripts/deploy.sh" juan --node b --json --dry-run 2>"$REPO/err")"
  rc=$?
  assert_eq "$rc" 2 "--node y NODE_ID distintos => INVALID_INPUT"
  assert_contains "$out" 'no coinciden' "el mensaje explica el conflicto"
}

test_flag_inexistente() {
  make_repo
  write_instance "$REPO" juan
  write_node "$REPO" a ws 4500 ""
  local out rc
  out="$(run_deploy "$REPO" juan --node z --json --dry-run 2>"$REPO/err")"
  rc=$?
  assert_eq "$rc" 2 "--node inexistente => INVALID_INPUT"
  assert_contains "$out" "nodo 'z' no existe" "el mensaje nombra el nodo pedido"
  assert_contains "$out" 'válidos: a' "el mensaje lista los válidos"
}

test_dos_instancias() {
  make_repo
  write_instance "$REPO" juan
  write_instance "$REPO" pedro
  write_node "$REPO" a ws 4500 ""
  local out rc
  out="$(run_deploy "$REPO" --all --node a --json --dry-run 2>"$REPO/err")"
  rc=$?
  assert_eq "$rc" 0 "--all despliega todas"
  assert_contains "$out" '"sandboxId":"sandbox-juan"' "incluye juan"
  assert_contains "$out" '"sandboxId":"sandbox-pedro"' "incluye pedro"
  assert_contains "$out" '"containerName":"alice-sandbox-juan"' "juan con su containerName"
  assert_contains "$out" '"containerName":"alice-sandbox-pedro"' "pedro con su containerName"
  assert_json_valid "$out" "JSON de --all válido"
}

# ---------------------------------------------------------------------------
# Topología
# ---------------------------------------------------------------------------

test_topologia_vacia() {
  make_repo
  write_instance "$REPO" juan
  write_node "$REPO" a "" 4500 ""
  local out rc
  out="$(run_deploy "$REPO" juan --node a --json --dry-run 2>"$REPO/err")"
  rc=$?
  assert_eq "$rc" 2 "SANDBOX_TRANSPORT vacío => INVALID_INPUT"
  assert_contains "$out" 'SANDBOX_TRANSPORT' "el mensaje nombra la topología que falta"
}

test_wss_sin_public_host() {
  make_repo
  write_instance "$REPO" juan
  write_node "$REPO" vps wss 443 ""
  local out rc
  out="$(run_deploy "$REPO" juan --node vps --json --dry-run 2>"$REPO/err")"
  rc=$?
  assert_eq "$rc" 2 "wss sin SANDBOX_PUBLIC_HOST => exit 2"
  assert_contains "$out" '"code":"INVALID_INPUT"' "wss sin host => INVALID_INPUT"
  assert_contains "$out" 'SANDBOX_PUBLIC_HOST' "el mensaje nombra la variable que falta"
  assert_json_valid "$out" "el error es JSON válido"
}

test_ws_con_public_host_avisa() {
  make_repo
  write_instance "$REPO" juan
  write_node "$REPO" lb ws 8080 lb.internal
  local out err rc
  out="$(run_deploy "$REPO" juan --node lb --json --dry-run 2>"$REPO/err")"
  rc=$?
  err="$(cat "$REPO/err")"
  assert_eq "$rc" 0 "ws con SANDBOX_PUBLIC_HOST es legal"
  assert_contains "$err" 'SANDBOX_PUBLIC_HOST' "aviso por stderr"
  assert_contains "$out" '"internalHost":"lb.internal"' "internalHost usa el host público"
  assert_contains "$out" '"port":8080' "respeta SANDBOX_PORT"
}

test_wss_default_port() {
  make_repo
  write_instance "$REPO" juan
  write_node "$REPO" vps wss "" tunnel.example.com
  local out rc
  out="$(run_deploy "$REPO" juan --node vps --json --dry-run 2>"$REPO/err")"
  rc=$?
  assert_eq "$rc" 0 "wss sin SANDBOX_PORT usa 443"
  assert_contains "$out" '"port":443' "default 443 con wss"
}

test_ws_default_port() {
  make_repo
  write_instance "$REPO" juan
  write_node "$REPO" host ws "" ""
  local out rc
  out="$(run_deploy "$REPO" juan --node host --json --dry-run 2>"$REPO/err")"
  rc=$?
  assert_eq "$rc" 0 "ws sin SANDBOX_PORT usa 4500"
  assert_contains "$out" '"port":4500' "default 4500 con ws"
}

# ---------------------------------------------------------------------------
# Validaciones de instancia
# ---------------------------------------------------------------------------

test_hash_vacio() {
  make_repo
  write_instance "$REPO" juan "sandbox-juan" ""
  write_node "$REPO" a ws 4500 ""
  local out rc
  out="$(run_deploy "$REPO" juan --node a --json --dry-run 2>"$REPO/err")"
  rc=$?
  assert_eq "$rc" 2 "WS_TOKEN_SHA256 vacío => INVALID_INPUT"
  assert_contains "$out" 'WS_TOKEN_SHA256' "el mensaje nombra el hash"
}

test_hash_no_hex() {
  make_repo
  write_instance "$REPO" juan "sandbox-juan" "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"
  write_node "$REPO" a ws 4500 ""
  local out rc
  out="$(run_deploy "$REPO" juan --node a --json --dry-run 2>"$REPO/err")"
  rc=$?
  assert_eq "$rc" 2 "WS_TOKEN_SHA256 no-hex => INVALID_INPUT"
  assert_contains "$out" 'WS_TOKEN_SHA256' "el mensaje nombra el hash"
}

test_hash_mayusculas() {
  make_repo
  write_instance "$REPO" juan "sandbox-juan" "$HASH_UPPER"
  write_node "$REPO" a ws 4500 ""
  local out rc log
  out="$(FAKE_DOCKER_LOG="$REPO/docker.log" FAKE_DOCKER_COMPOSE_RC=0 \
    run_deploy "$REPO" juan --node a --json --no-wait-ready 2>"$REPO/err")"
  rc=$?
  log="$(cat "$REPO/docker.log" 2>/dev/null || true)"
  assert_eq "$rc" 0 "hash en MAYÚSCULAS se acepta"
  assert_contains "$out" '"ok":true' "hash en MAYÚSCULAS produce ok"
  assert_contains "$log" "WS_TOKEN_SHA256=$HASH_DEFAULT" "el hash se normaliza a minúsculas"
  assert_not_contains "$log" "WS_TOKEN_SHA256=$HASH_UPPER" "no se propaga el hash en mayúsculas"
}

test_tag_latest() {
  make_repo
  write_instance "$REPO" juan "sandbox-juan" "$HASH_DEFAULT" latest
  write_node "$REPO" a ws 4500 ""
  local out rc
  out="$(run_deploy "$REPO" juan --node a --json --dry-run 2>"$REPO/err")"
  rc=$?
  assert_eq "$rc" 2 "LETTA_TAG=latest => INVALID_INPUT"
  assert_contains "$out" '"code":"INVALID_INPUT"' "latest devuelve el código INVALID_INPUT"
  assert_contains "$out" "latest" "el mensaje menciona latest"
}

test_tag_latest_mayusculas() {
  make_repo
  write_instance "$REPO" juan "sandbox-juan" "$HASH_DEFAULT" LATEST
  write_node "$REPO" a ws 4500 ""
  local out rc
  out="$(run_deploy "$REPO" juan --node a --json --dry-run 2>"$REPO/err")"
  rc=$?
  assert_eq "$rc" 2 "LETTA_TAG=LATEST => INVALID_INPUT"
  assert_contains "$out" '"code":"INVALID_INPUT"' "LATEST también se rechaza"
}

test_sandbox_vacio() {
  make_repo
  write_instance "$REPO" juan "" "$HASH_DEFAULT" "0.34.39"
  write_node "$REPO" a ws 4500 ""
  local out rc
  out="$(run_deploy "$REPO" juan --node a --json --dry-run 2>"$REPO/err")"
  rc=$?
  assert_eq "$rc" 2 "ALICE_SANDBOX_ID vacío => INVALID_INPUT"
  assert_contains "$out" 'ALICE_SANDBOX_ID' "el mensaje nombra el id del sandbox"
}

test_sandbox_repetido() {
  make_repo
  write_instance "$REPO" juan
  write_instance "$REPO" pedro "sandbox-juan"
  write_node "$REPO" a ws 4500 ""
  local out rc
  out="$(run_deploy "$REPO" --all --node a --json --dry-run 2>"$REPO/err")"
  rc=$?
  assert_eq "$rc" 2 "ALICE_SANDBOX_ID repetido => INVALID_INPUT"
  assert_contains "$out" 'repetido' "el mensaje explica la colisión de container_name"
}

test_sandbox_invalido() {
  make_repo
  write_instance "$REPO" juan "-empieza-con-guion"
  write_node "$REPO" a ws 4500 ""
  local out rc
  out="$(run_deploy "$REPO" juan --node a --json --dry-run 2>"$REPO/err")"
  rc=$?
  assert_eq "$rc" 2 "ALICE_SANDBOX_ID que empieza por - => INVALID_INPUT"
  assert_contains "$out" 'ALICE_SANDBOX_ID' "el mensaje nombra el id inválido"
}

test_job_falta() {
  make_repo
  write_instance "$REPO" juan "sandbox-juan" "$HASH_DEFAULT" "0.34.39" ""
  write_node "$REPO" a ws 4500 ""
  local out rc
  out="$(run_deploy "$REPO" juan --node a --json --dry-run 2>"$REPO/err")"
  rc=$?
  assert_eq "$rc" 2 "ALICE_JOB_ID vacío => INVALID_INPUT"
  assert_contains "$out" 'ALICE_JOB_ID' "el mensaje nombra el job"
}

test_user_falta() {
  make_repo
  write_instance "$REPO" juan "sandbox-juan" "$HASH_DEFAULT" "0.34.39" "job-juan" ""
  write_node "$REPO" a ws 4500 ""
  local out rc
  out="$(run_deploy "$REPO" juan --node a --json --dry-run 2>"$REPO/err")"
  rc=$?
  assert_eq "$rc" 2 "ALICE_USER_ID vacío => INVALID_INPUT"
  assert_contains "$out" 'ALICE_USER_ID' "el mensaje nombra el usuario"
}

# ---------------------------------------------------------------------------
# Readiness y fallos de docker
# ---------------------------------------------------------------------------

test_ready_timeout() {
  make_repo
  write_instance "$REPO" juan
  write_node "$REPO" a ws 4500 ""
  local out rc start elapsed
  start=$SECONDS
  out="$(cd "$REPO" && DOCKER_BIN="$REPO/scripts/fake-docker.sh" READY_CHECK_CMD=false \
    bash "$REPO/scripts/deploy.sh" juan --node a --json --ready-timeout 1 2>"$REPO/err")"
  rc=$?
  elapsed=$((SECONDS - start))
  assert_eq "$rc" 1 "readiness agotado => exit 1 (fallo de ejecución)"
  assert_contains "$out" '"code":"READY_TIMEOUT"' "código READY_TIMEOUT"
  assert_contains "$out" '"containerId"' "incluye containerId"
  if [ "$elapsed" -lt 3 ]; then
    pass "READY_TIMEOUT respeta --ready-timeout 1 (${elapsed}s)"
  else
    fail "READY_TIMEOUT tardó ${elapsed}s (esperado <3s)"
  fi
}

test_ready_ok() {
  make_repo
  write_instance "$REPO" juan
  write_node "$REPO" a ws 4500 ""
  local out rc
  out="$(run_deploy "$REPO" juan --node a --json 2>"$REPO/err")"
  rc=$?
  assert_eq "$rc" 0 "readiness OK (fake docker exec) => exit 0"
  assert_contains "$out" '"ok":true' "resultado ok"
  assert_contains "$out" '"containerId":"cid-alice-sandbox-juan"' "containerId sale de docker inspect"
  assert_json_valid "$out" "JSON de deploy con readiness válido"
}

test_no_wait_ready() {
  make_repo
  write_instance "$REPO" juan
  write_node "$REPO" a ws 4500 ""
  local out rc
  out="$(cd "$REPO" && DOCKER_BIN="$REPO/scripts/fake-docker.sh" READY_CHECK_CMD=false \
    bash "$REPO/scripts/deploy.sh" juan --node a --json --no-wait-ready 2>"$REPO/err")"
  rc=$?
  assert_eq "$rc" 0 "--no-wait-ready no consulta /readyz"
  assert_contains "$out" '"ok":true' "resultado ok sin esperar readiness"
}

test_deploy_failed() {
  make_repo
  write_instance "$REPO" juan
  write_node "$REPO" a ws 4500 ""
  make_failing_docker "$REPO"
  local out rc
  out="$(cd "$REPO" && DOCKER_BIN="$REPO/scripts/fail-docker.sh" \
    bash "$REPO/scripts/deploy.sh" juan --node a --json --no-wait-ready 2>"$REPO/err")"
  rc=$?
  assert_eq "$rc" 1 "docker compose falla => exit 1 (no 2)"
  assert_contains "$out" '"code":"DEPLOY_FAILED"' "código DEPLOY_FAILED"
  assert_not_contains "$out" 'INVALID_INPUT' "un fallo de ejecución no es INVALID_INPUT"
}

# ---------------------------------------------------------------------------
# Modo manager: entorno manda, sin instance file
# ---------------------------------------------------------------------------

test_env_precedence() {
  make_repo
  write_instance "$REPO" juan "sandbox-file"
  write_node "$REPO" a ws 4500 ""
  local out rc
  out="$(ALICE_JOB_ID=job-env ALICE_USER_ID=user-env ALICE_SANDBOX_ID=sandbox-env \
    run_deploy "$REPO" juan --node a --json --dry-run 2>"$REPO/err")"
  rc=$?
  assert_eq "$rc" 0 "el manager puede pisar el instance file"
  assert_contains "$out" '"sandboxId":"sandbox-env"' "ALICE_SANDBOX_ID del manager gana"
  assert_contains "$out" '"containerName":"alice-sandbox-env"' "containerName usa el id del manager"
  assert_not_contains "$out" 'sandbox-file' "no se contamina con el sandbox del archivo"
}

test_manager_env_only() {
  make_repo
  write_node "$REPO" a ws 4500 ""
  local out rc
  out="$(ALICE_JOB_ID=job-1 ALICE_USER_ID=user-1 ALICE_SANDBOX_ID=sb-1 \
    WS_TOKEN_SHA256=$HASH_DEFAULT LETTA_TAG=0.34.39 \
    LITELLM_BASE_URL=http://litellm:4000 LITELLM_API_KEY=sk-test \
    run_deploy "$REPO" --node a --json --dry-run 2>"$REPO/err")"
  rc=$?
  assert_eq "$rc" 0 "provision sin instance file (solo env) funciona"
  assert_contains "$out" '"sandboxId":"sb-1"' "sandboxId desde el entorno"
  assert_contains "$out" '"containerName":"alice-sb-1"' "containerName desde el entorno"
  assert_contains "$out" '"ok":true' "results[] ok"
}

test_compose_args() {
  make_repo
  write_instance "$REPO" juan
  write_node "$REPO" a ws 4500 ""
  local out rc log
  out="$(FAKE_DOCKER_LOG="$REPO/docker.log" run_deploy "$REPO" juan --node a --json --no-wait-ready 2>"$REPO/err")"
  rc=$?
  log="$(cat "$REPO/docker.log" 2>/dev/null || true)"
  assert_eq "$rc" 0 "deploy con fake docker"
  assert_contains "$log" 'compose -p alice-sandbox-juan' "proyecto -p alice-<sandboxId>"
  assert_contains "$log" 'nodes/a.env' "pasa el env-file del nodo"
  assert_contains "$log" 'instances/juan.env' "pasa el env-file de la instancia"
}

# ---------------------------------------------------------------------------
# Forma del JSON y dry-run
# ---------------------------------------------------------------------------

test_json_stdout_limpio() {
  make_repo
  write_instance "$REPO" juan
  write_node "$REPO" a ws 4500 ""
  local out rc
  out="$(run_deploy "$REPO" juan --node a --json --dry-run 2>"$REPO/err")"
  rc=$?
  assert_eq "$rc" 0 "dry-run --json"
  assert_not_contains "$out" '[fake-docker]' "stdout solo JSON, sin logs"
  assert_json_valid "$out" "stdout es JSON parseable"
}

test_dry_run_sin_docker() {
  make_repo
  write_instance "$REPO" juan
  write_node "$REPO" a ws 4500 ""
  local rc
  FAKE_DOCKER_LOG="$REPO/docker.log" run_deploy "$REPO" juan --node a --json --dry-run >/dev/null 2>"$REPO/err"
  rc=$?
  assert_eq "$rc" 0 "dry-run termina bien"
  assert_file_absent "$REPO/docker.log" "--dry-run no invoca docker"
}

test_results_keys() {
  make_repo
  write_instance "$REPO" juan
  write_node "$REPO" a ws 4500 ""
  local out rc
  out="$(run_deploy "$REPO" juan --node a --json --dry-run 2>"$REPO/err")"
  rc=$?
  assert_eq "$rc" 0 "results[] generado"
  assert_contains "$out" '"sandboxId"' "item tiene sandboxId"
  assert_contains "$out" '"containerName"' "item tiene containerName"
  assert_contains "$out" '"containerId"' "item tiene containerId"
  assert_contains "$out" '"internalHost"' "item tiene internalHost"
  assert_contains "$out" '"port"' "item tiene port"
  assert_contains "$out" '"transport"' "item tiene transport"
}

test_error_json_shape() {
  make_repo
  write_instance "$REPO" juan "sandbox-juan" "no-hex"
  write_node "$REPO" a ws 4500 ""
  local out rc
  out="$(run_deploy "$REPO" juan --node a --json --dry-run 2>"$REPO/err")"
  rc=$?
  assert_eq "$rc" 2 "input inválido => exit 2"
  assert_contains "$out" '"ok":false' "error trae ok:false"
  assert_contains "$out" '"code":"INVALID_INPUT"' "error trae code INVALID_INPUT"
  assert_json_valid "$out" "error es JSON parseable"
}

test_list_json_invalido() {
  make_repo
  write_instance "$REPO" juan
  write_node "$REPO" a ws 4500 ""
  local out rc
  out="$(run_deploy "$REPO" --list --json 2>"$REPO/err")"
  rc=$?
  assert_eq "$rc" 2 "--list --json => INVALID_INPUT"
  assert_contains "$out" '"code":"INVALID_INPUT"' "código INVALID_INPUT"
}

# ---------------------------------------------------------------------------
# Contrato estático de docker-compose.yml
# ---------------------------------------------------------------------------

test_compose_contract() {
  local f="$ROOT/docker-compose.yml"
  assert_no_line "$f" '^[[:space:]]*ports:' "compose no publica puertos"
  assert_has_line "$f" 'container_name: alice-\$\{ALICE_SANDBOX_ID' "container_name por ALICE_SANDBOX_ID"
  assert_has_line "$f" 'alice\.jobId: \$\{ALICE_JOB_ID:\?' "label alice.jobId obligatoria"
  assert_has_line "$f" 'alice\.userId: \$\{ALICE_USER_ID:\?' "label alice.userId obligatoria"
  assert_has_line "$f" 'alice\.sandboxId: \$\{ALICE_SANDBOX_ID:\?' "label alice.sandboxId obligatoria"
  assert_has_line "$f" 'external: true' "red sandboxes externa"
  assert_has_line "$f" 'name: \$\{SANDBOX_NETWORK:-sandboxes\}' "nombre de red configurable"
  assert_has_line "$f" 'ws-token-sha256' "command usa --ws-token-sha256"
  assert_has_line "$f" 'fetch\(' "healthcheck con fetch (node)"
  assert_no_line "$f" '^[[:space:]]*secrets:' "sin montaje de secrets"
  assert_no_line "$f" 'ws-token-file' "sin --ws-token-file"
}

# ---------------------------------------------------------------------------

test_un_nodo_auto_avisa
test_cero_nodos
test_dos_nodos_sin_flag
test_dos_nodos_con_flag
test_flag_y_env_distintos
test_flag_inexistente
test_dos_instancias
test_topologia_vacia
test_wss_sin_public_host
test_ws_con_public_host_avisa
test_wss_default_port
test_ws_default_port
test_hash_vacio
test_hash_no_hex
test_hash_mayusculas
test_tag_latest
test_tag_latest_mayusculas
test_sandbox_vacio
test_sandbox_repetido
test_sandbox_invalido
test_job_falta
test_user_falta
test_ready_timeout
test_ready_ok
test_no_wait_ready
test_deploy_failed
test_env_precedence
test_manager_env_only
test_compose_args
test_json_stdout_limpio
test_dry_run_sin_docker
test_results_keys
test_error_json_shape
test_list_json_invalido
test_compose_contract

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
