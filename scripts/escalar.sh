#!/usr/bin/env bash
# Escala un servicio del stack (IE8) y muestra en qué nodos quedaron las réplicas.
#   ./escalar.sh ms-agenda 6
source "$(dirname "$0")/comun.sh"
SERVICIO="${1:?Uso: $0 <servicio> <réplicas>}"; REPLICAS="${2:?Uso: $0 <servicio> <réplicas>}"
en "$(manager_ip)" "docker service scale rys_${SERVICIO}=${REPLICAS} && docker service ps rys_${SERVICIO} --filter desired-state=running --format 'table {{.Name}}\t{{.Node}}\t{{.CurrentState}}'"
