# alice-ops — despliegue de instancias de Letta

Una instancia = **un** App Server de Letta (`letta server`) en su propio
contenedor, con su volumen y su `.env`. No hay puertos publicados en el host:
el contenedor vive en la red Docker `sandboxes` y el gateway lo alcanza por DNS
interno, o por el túnel del nodo cuando el transporte es `wss`.

`deploy.sh` es idempotente y tiene un modo `--json` pensado para el **Sandbox
Manager**: stdout solo lleva JSON, los logs van por stderr.

```
nodes/_ejemplo.env          topología del nodo (ws/wss, puerto, host)
instances/_ejemplo.env      datos por instancia (USER_NAME, ALICE_JOB_ID, ALICE_USER_ID, ALICE_SANDBOX_ID, LETTA_TAG, hash, LiteLLM)
docker-compose.yml          servicio por instancia, sin `ports:`
docker-compose.watchtower.yml
scripts/deploy.sh           deploy: <instancia> | --all | --list [--node <nodo>] [--json]
                            sin <instancia>: modo manager, toma todo del entorno
scripts/fake-docker.sh      doble de docker para tests sin Docker
tests/deploy-test.sh        contrato de deploy.sh (nodo, transporte, JSON)
```

## Cambios respecto a la versión inicial

- **El puerto ya no se publica.** El contenedor vive en la red externa
  `sandboxes` (`name: ${SANDBOX_NETWORK:-sandboxes}`) y el gateway lo alcanza
  por DNS interno (`alice-<ALICE_SANDBOX_ID>:4500`) o por el túnel del nodo.
- **El token no vive en el contenedor.** El contenedor guarda solo su
  `sha256` (`--ws-token-sha256`); el token en claro está cifrado en PostgreSQL.
- **`--ws-token-sha256` no está en docs.letta.com.** Solo existe en el
  binario; por eso `LETTA_TAG` nunca es `latest` (sin rollback).
- **Contrato `deploy.sh --json`.** stdout solo JSON: `results[]` con
  `sandboxId`, `containerName`, `internalHost`, `port`, `transport` y
  `containerId`. Exit 0 ok, 1 fallo de ejecución (`DEPLOY_FAILED`,
  `READY_TIMEOUT`), 2 input inválido (`INVALID_INPUT`).
- **Precedencia de entorno.** Lo que exporta el manager (`ALICE_JOB_ID`,
  `ALICE_USER_ID`, `ALICE_SANDBOX_ID`, `WS_TOKEN_SHA256`) gana sobre
  `instances/*.env`; sin `<instancia>` deploy.sh funciona solo con el entorno.
- **El hash se calcula sobre el STRING base64url** que viaja en
  `Authorization: Bearer`, no sobre los 32 bytes crudos.
- **Verificación pendiente en el host:**
  `docker run --rm letta/letta:0.34.39 sh -c 'which node; node -v'`; si falta
  `node`, usar la variante `wget` como fallback.

## Identidad del sandbox

El nombre del contenedor es `alice-<ALICE_SANDBOX_ID>`, donde
`ALICE_SANDBOX_ID` es el id de la fila `containers` (lo asigna el Sandbox
Manager). Para el nombre del contenedor no se usa `USER_NAME`:

- `container_name` es único en el host Docker; dos re-provisions del mismo
  usuario (decisión C: 3 fallos → borrar y crear) colisionarían con
  `<USER_NAME>-server-instance`.
- `USER_NAME` es un nombre humano y Docker lo trata sin distinguir mayúsculas:
  "juan" y "Juan" chocan.
- `ALICE_SANDBOX_ID` es único por sandbox, así que el endpoint del JSON es
  `internalHost = "alice-<ALICE_SANDBOX_ID>"`.

`USER_NAME` se conserva como etiqueta humana (`alice.instance`) y no identifica
al sandbox. `deploy.sh` fija el proyecto Compose con `-p alice-<ALICE_SANDBOX_ID>`.

## Topología del nodo (`nodes/`)

La topología es del **nodo**, no del usuario. Todos los sandboxes de un host
comparten estas variables; por eso viven en `nodes/<nodo>.env` y no en
`instances/<usuario>.env`.

| Variable | Valores | Por qué existe |
|---|---|---|
| `SANDBOX_TRANSPORT` | `ws` \| `wss` | `ws` = red Docker `sandboxes` del mismo host; `wss` = Cloudflare Tunnel / VPS remoto. Obligatoria. |
| `SANDBOX_PORT` | `4500` (ws) \| `443` (wss) | Puerto que usan el gateway/backend para conectar. **No** es el puerto interno: el App Server siempre escucha en `ws://0.0.0.0:4500`. Si falta, default 4500 con `ws` y 443 con `wss`. |
| `SANDBOX_PUBLIC_HOST` | hostname o vacío | Endpoint que resuelve al sandbox. Vacío con `ws` = nombre del contenedor. Con `wss` es obligatorio: un túnel sin hostname no es alcanzable. |
| `SANDBOX_NETWORK` | `sandboxes` (opcional) | Nombre de la red Docker externa que comparten gateway y sandboxes. Default `sandboxes`. |

Reglas de `deploy.sh`:

- `--node <id>` gana sobre `NODE_ID`.
- Si no hay ninguno y existe **exactamente un** `nodes/*.env`, lo usa y avisa
  por stderr. Con 0 o ≥2 nodos: `INVALID_INPUT` (exit 2) listando los válidos.
- `--node` y `NODE_ID` distintos → `INVALID_INPUT` (no adivina).
- `--node` inexistente → `INVALID_INPUT` nombrando los válidos.
- `ws` + `SANDBOX_PUBLIC_HOST` definido es legal (p. ej. LB interno), pero
  `deploy.sh` avisa por stderr para que sea una decisión consciente.

Casos típicos:

| Dónde vive el sandbox | `transport` | `port` | `internalHost` que devuelve el JSON |
|---|---|---|---|
| Mismo host, red `sandboxes` | `ws` | `4500` | `alice-<ALICE_SANDBOX_ID>` |
| Cloudflare Tunnel / VPS remoto | `wss` | `443` | `SANDBOX_PUBLIC_HOST` |

## Flujo

```bash
# una vez por host: red compartida con el gateway
docker network create sandboxes

# topología del nodo
cp nodes/_ejemplo.env nodes/vps-1.env && $EDITOR nodes/vps-1.env

# instancia (ALICE_SANDBOX_ID lo asigna el manager: id de la fila containers)
cp instances/_ejemplo.env instances/alice-123.env && $EDITOR instances/alice-123.env
chmod 600 instances/*.env nodes/*.env

# el hash se calcula en el backend con el token en claro; nunca hace falta
# escribir el token en el host. Para verificarlo a mano:
printf '%s' "$TOKEN" | sha256sum | cut -d' ' -f1   # -> WS_TOKEN_SHA256

./scripts/deploy.sh alice-123 --node vps-1 --dry-run
./scripts/deploy.sh alice-123 --node vps-1
./scripts/deploy.sh alice-123 --node vps-1 --json
./scripts/deploy.sh --list

# modo manager (sin instancia): todo por entorno; el entorno GANA sobre el .env
ALICE_JOB_ID=... ALICE_USER_ID=... ALICE_SANDBOX_ID=... WS_TOKEN_SHA256=... \
  ./scripts/deploy.sh --node vps-1 --json
```

Actualizar una instancia = cambiar `LETTA_TAG` en su `.env` y
`deploy.sh <user> --node <nodo>`. Volver atrás = poner el tag anterior y
redeploy.

> **El tag nunca es `latest`.** `--ws-token-sha256` no está en docs.letta.com:
> solo existe en el binario. Una imagen nueva puede quitarlo o cambiarlo, así
> que cada subida de `LETTA_TAG` debe revalidar `letta server --help`. `deploy.sh`
> rechaza `LETTA_TAG=latest` y exige un tag fijo.

## Contrato `--json` (Sandbox Manager)

`deploy.sh` espera a que `/readyz` responda antes de declarar éxito. La salida
por **stdout** es solo JSON; `docker compose`, avisos y errores de ejecución van
por **stderr**.

```json
{"ok":true,"results":[{"ok":true,"sandboxId":"7f3c2a1b","containerName":"alice-7f3c2a1b","internalHost":"alice-7f3c2a1b","port":4500,"transport":"ws","containerId":"3f2a..."}]}
```

Si una instancia falla, el array trae el fallo y el proceso sale con 1. El
contenedor **no** se borra: decide el manager (reintento y cleanup).

```json
{"ok":false,"results":[
  {"ok":true,"sandboxId":"7f3c2a1b","containerName":"alice-7f3c2a1b","internalHost":"alice-7f3c2a1b","port":4500,"transport":"ws","containerId":"3f2a..."},
  {"ok":false,"sandboxId":"9b1c4d2e","containerName":"alice-9b1c4d2e","code":"READY_TIMEOUT","message":"sin respuesta en /readyz tras 90s","containerId":"9b1c..."}
]}
```

Entrada inválida (topología, hash, instancia, tag): JSON de error por stdout y
exit 2. No es reintentable.

```json
{"ok":false,"code":"INVALID_INPUT","message":"SANDBOX_PUBLIC_HOST es obligatorio con SANDBOX_TRANSPORT=wss (un túnel sin hostname no es alcanzable)"}
```

Códigos de salida:

| Exit | Significado |
|---|---|
| 0 | todo desplegado y listo |
| 1 | fallo de ejecución (`DEPLOY_FAILED`, `READY_TIMEOUT`); el manager puede reintentar |
| 2 | `INVALID_INPUT`; reintentar no sirve, hay que corregir la entrada |

Opciones de readiness:

- `--ready-timeout <s>`: default 90.
- `--no-wait-ready`: no espera `/readyz` (depuración / modo rápido del manager).
- `READY_CHECK_CMD`: comando ejecutado **en el host**; recibe `DOCKER` y
  `CONTAINER_NAME`. Por defecto,
  `"$DOCKER" exec "$CONTAINER_NAME" node -e "fetch('http://127.0.0.1:4500/readyz')..."`.
  Sirve para tests (`READY_CHECK_CMD=false`) y para cambiar a `wget` si la
  imagen no trae node, sin tocar el compose.

### Verificación pendiente en el host

El healthcheck del compose y el poll de `deploy.sh` asumen que `node` existe
**dentro** de la imagen. Eso no se puede verificar desde esta máquina (no hay
Docker). Antes de dar el nodo por bueno, ejecutar en el LXC/host:

```bash
docker run --rm letta/letta:0.34.39 sh -c 'which node; node -v'
```

- **Si imprime una ruta y `v22.x`:** dejar el healthcheck actual
  (`CMD node -e ...`) y el `READY_CHECK_CMD` por defecto.
- **Si `which` no encuentra node:** cambiar el healthcheck del compose a:
  ```yaml
  test: ["CMD-SHELL", "wget -q -O- http://127.0.0.1:4500/readyz || exit 1"]
  ```
  y usar el mismo chequeo en `deploy.sh`:
  ```bash
  READY_CHECK_CMD='"$DOCKER" exec "$CONTAINER_NAME" wget -q -O- http://127.0.0.1:4500/readyz >/dev/null' \
    ./scripts/deploy.sh <instancia> --node <nodo> --json
  ```
  La imagen también instala `wget` según su Dockerfile; confírmalo con
  `docker run --rm letta/letta:0.34.39 sh -c 'which wget; wget --version | head -1'`.

La variante que hay que confirmar en el LXC es **node**; la de **wget** es solo
el fallback. No cambiar el compose a wget sin haber visto que node falta.

`docker compose` recibe dos `--env-file`: `nodes/<nodo>.env` y
`instances/<user>.env`. Así la topología también está disponible para la
interpolación del compose (`SANDBOX_NETWORK`).

## Seguridad del capability token

- El contenedor **no** monta el token. Recibe solo su digest:
  `--ws-token-sha256 <64 hex>`.
- El hash se calcula sobre el **string base64url** del token (lo que viaja en
  `Authorization: Bearer`), no sobre los 32 bytes crudos. Si el backend hashea
  bytes, el handshake falla aunque el token sea correcto.
- `--ws-auth capability-token` sigue siendo obligatorio: el flag del hash **no**
  reemplaza al modo de auth, y es mutuamente excluyente con `--ws-token-file`.
- El token en claro vive cifrado en PostgreSQL (backend). `alice-ops` nunca lo
  ve: solo recibe el hash en `WS_TOKEN_SHA256` (que no es secreto).
- Rotar el token = recalcular el hash, actualizar `WS_TOKEN_SHA256` y recrear el
  contenedor (`deploy.sh`). El proceso lee el hash al arrancar; un restart no
  basta si cambió.

Verificado con `letta-code@0.34.39` (la misma versión que instala la imagen):

```
--ws-token-sha256 <hex>  Hex-encoded SHA-256 digest of the capability token
```

## Actualización automática

`docker compose -f docker-compose.watchtower.yml up -d`

Solo toca contenedores con `com.centurylinklabs.watchtower.enable=true`.
`ROLLING_RESTART` reinicia de a uno. **Pero el compose usa tag fijo**, así que
Watchtower no detectará nada nuevo: con tags fijos la actualización es
deliberada. Elige uno de los dos caminos y no los mezcles.

## Créditos y LiteLLM

LiteLLM como proxy, **API OpenAI-compatible, una virtual key por usuario**.
Verificado en el bundle que Letta lo soporta de primera clase:

- `protocol_v2.d.ts`: `reasoning_effort` con el comentario *"Explicit effort for
  an OpenAI-compatible proxy"*.
- `model_handle` con ejemplo `"anthropic/claude-sonnet-4-6"` → el prefijo
  `openai/...` es un handle normal.
- SDK de OpenAI embebido: `baseURL = readEnv("OPENAI_BASE_URL")`.
- BYOK formal: `connect_provider` + `byok_provider_aliases`.

El compose pasa `OPENAI_BASE_URL` + `OPENAI_API_KEY`. **El titular del token es
el agente dentro del contenedor**, no un humano con shell aparte: el contenedor
es la jaula. El riesgo no es "el usuario lo roba" sino "el agente lo filtra por
prompt injection", acotado por el budget y los modelos permitidos de la virtual
key.

### Modelo de amenaza que queda

| Riesgo | Cubierto por |
|---|---|
| Usuario usa LiteLLM fuera de Alice | No aplica: no tiene acceso fuera del contenedor |
| Agente filtra la key (injection) | Budget + `models:` de la virtual key + rotación |
| Gasto anómalo | `metadata` de LiteLLM por key → atribución por tenant |
| Reinicio pierde la key | Env var, la vuelve a tomar el compose |

### La trampa de la env var

La config persistida del proveedor **gana** sobre la env var
(`config.base_url ?? readEnv("OPENAI_BASE_URL")`). Si un agente hace `/connect`
o `update_model` con su propia URL, `OPENAI_BASE_URL` se ignora y las llamadas
salen a `api.openai.com` → 401 sin explicación. Si eso pasa, la ruta robusta es
`connect_provider` + `update_model` con `model_handle` explícito y la key en el
almacén local de proveedores. **No verificado en vivo.**

### Rotar una virtual key

Cambiar `LITELLM_API_KEY` en `instances/<user>.env` y
`deploy.sh <user> --node <nodo>` (recrea el contenedor). El estado vive en el
volumen `letta-state`, no se pierde.

## Tests

```bash
bash tests/deploy-test.sh
```

No requieren Docker: usan `scripts/fake-docker.sh`. Cubren selección de nodo
(0/1/2 nodos, `--node` vs `NODE_ID`, inexistente), `ws`/`wss`, defaults de
puerto, `ALICE_JOB_ID`/`ALICE_USER_ID`/`ALICE_SANDBOX_ID` obligatorios,
`ALICE_SANDBOX_ID` único (container_name), hash vacío/no-hex/mayúsculas,
`LETTA_TAG=latest`, precedencia del entorno del manager sobre el `.env`,
`INVALID_INPUT`, `READY_TIMEOUT`, `DEPLOY_FAILED`, la forma de `results[]`
(`sandboxId`/`containerName`) y el contrato estático de `docker-compose.yml`.

## Lo que NO resuelve

- **No escala en 4 GB.** Un contenedor por usuario son ~250-300 MB idle. 6-8 y el LXC
  se queda sin RAM. Para beta cerrada de 5-8 está bien; para más, otro nodo.
- **Los parches al runtime se pierden.** Los parches de Baileys/transcripción viven en
  `/usr/local/lib/node_modules/@letta-ai/letta-code`; una imagen nueva los borra.
  Sin un `Dockerfile` propio que los aplique, cada actualización rompe WhatsApp.
- **Rotar el token requiere recrear**, no reiniciar: el proceso lee el hash al arrancar.
- **Sin puertos publicados no hay `localhost:4500` para depurar.** Usa
  `docker exec` o un contenedor temporal en la red `sandboxes`.
- **Watchtower = root en el host** (socket de Docker). Si más adelante hay contenedores
  de terceros en la misma máquina, ya no es aceptable montarlo así.
- **`--ws-token-sha256` no está documentado.** Está en el binario 0.34.39, no en
  docs.letta.com. Revalida el flag en cada cambio de tag; el compose fija una
  versión concreta, nunca `latest`.
