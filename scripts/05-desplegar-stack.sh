#!/usr/bin/env bash
# Despliega (o actualiza) el stack "rys" en el clúster Swarm (IE3/IE7).
#  · crea los secretos de Swarm si no existen (desde variables de entorno / secrets del pipeline)
#  · inicia sesión en Amazon ECR con el rol de la instancia y despliega con --with-registry-auth
#  · espera a que todos los servicios converjan (réplicas healthy)
# Requiere: DB_PASSWORD, ORIGIN_SECRET, CLINICO_CRYPTO_KEY, PAGOS_WEBHOOK_SECRET. Opcional: TAG (latest).
source "$(dirname "$0")/comun.sh"
: "${DB_PASSWORD:?}" "${ORIGIN_SECRET:?}" "${CLINICO_CRYPTO_KEY:?}" "${PAGOS_WEBHOOK_SECRET:?}"
MANAGER=$(manager_ip)
REGISTRY=$(salida "$STACK_SERVICIOS" RegistroEcr)
DB_HOST=$(salida "$STACK_SERVICIOS" DbEndpoint)
COLA=$(salida "$STACK_SERVICIOS" ColaCitasUrl)
TAG="${TAG:-latest}"

info "Copiando definición del stack al manager"
en "$MANAGER" 'mkdir -p ~/rys/edge'
copiar "$RAIZ/docker-compose.yml" "${SSH_USER}@${MANAGER}:rys/docker-compose.yml"
copiar "$RAIZ/edge/nginx.conf" "${SSH_USER}@${MANAGER}:rys/edge/nginx.conf"

info "Secretos de Swarm (se crean solo si no existen; son inmutables)"
crear_secreto() { # crear_secreto <nombre> <valor>
  printf '%s' "$2" | en "$MANAGER" "docker secret inspect $1 >/dev/null 2>&1 || docker secret create $1 - >/dev/null && echo '  · $1'"
}
crear_secreto rys_db_password "$DB_PASSWORD"
crear_secreto rys_clinico_crypto_key "$CLINICO_CRYPTO_KEY"
crear_secreto rys_pagos_webhook_secret "$PAGOS_WEBHOOK_SECRET"
crear_secreto rys_origin_secret_map "$(printf 'map $http_x_origin_verify $origen_valido {\n    default 0;\n    "%s" 1;\n}\n' "$ORIGIN_SECRET")"

info "docker stack deploy (imágenes $REGISTRY/rys/*:$TAG)"
en "$MANAGER" "cd ~/rys && aws ecr get-login-password --region $AWS_REGION | docker login -u AWS --password-stdin $REGISTRY >/dev/null \
  && REGISTRY=$REGISTRY TAG=$TAG DB_HOST=$DB_HOST SQS_COLA_CITAS_URL=$COLA EDGE_CONF_VERSION=$(shasum "$RAIZ/edge/nginx.conf" | cut -c1-10) \
     docker stack deploy -c docker-compose.yml --with-registry-auth --prune rys"

info "Esperando que todas las réplicas queden corriendo (máx. 10 min)"
en "$MANAGER" 'bash -s' <<'REMOTO'
for i in $(seq 1 60); do
  pendientes=$(docker stack services rys --format '{{.Name}} {{.Replicas}}' | awk '{split($2,r,"/"); if (r[1]!=r[2]) print $1" "$2}')
  [ -z "$pendientes" ] && break
  echo "  esperando: $(echo $pendientes | tr '\n' ' ')"; sleep 10
done
docker stack services rys
[ -z "$pendientes" ]
REMOTO
ok "Stack desplegado y convergido"
