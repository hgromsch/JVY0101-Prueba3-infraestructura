#!/usr/bin/env bash
# Construye y sube las 7 imágenes a Amazon ECR desde el equipo local (primer despliegue,
# antes de que existan los pipelines). Supone los repos ms-* clonados junto a este.
#   ./06-subir-imagenes.sh            → todas
#   ./06-subir-imagenes.sh ms-agenda  → solo una
source "$(dirname "$0")/comun.sh"
REGISTRY=$(salida "$STACK_SERVICIOS" RegistroEcr)
aws ecr get-login-password | docker login -u AWS --password-stdin "$REGISTRY" >/dev/null
SERVICIOS=("${@:-ms-identidad ms-psicologos ms-agenda ms-talleres ms-pagos ms-clinico ms-notificaciones}")
for ms in ${SERVICIOS[@]}; do
  VERSION=$(git -C "$RAIZ/../$ms" rev-parse --short HEAD 2>/dev/null || echo local)
  info "$ms → $REGISTRY/rys/$ms:{$VERSION,latest}"
  docker build --platform linux/amd64 --build-arg APP_VERSION="$VERSION" \
    -t "$REGISTRY/rys/$ms:$VERSION" -t "$REGISTRY/rys/$ms:latest" "$RAIZ/../$ms"
  docker push -q "$REGISTRY/rys/$ms:$VERSION" && docker push -q "$REGISTRY/rys/$ms:latest"
done
ok "Imágenes en ECR"
