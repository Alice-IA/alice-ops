#!/usr/bin/env bash
# Doble de `docker` para probar deploy.sh sin Docker instalado.
# `compose ... up -d` imprime lo que haría; `ps`/`inspect` no ensucian
# la salida JSON (inspect vacío => deploy.sh usa el nombre del contenedor).
case "$1" in
  ps) exit 0 ;;
  inspect) exit 0 ;;
esac
echo "[fake-docker] $*"
exit 0
