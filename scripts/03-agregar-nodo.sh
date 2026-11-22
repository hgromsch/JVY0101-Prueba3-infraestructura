#!/usr/bin/env bash
# Agrega un nodo nuevo (EC2 con Docker) al clúster como worker o manager (IE7).
#   ./03-agregar-nodo.sh <ip-publica-del-nodo> worker
#   ./03-agregar-nodo.sh <ip-publica-del-nodo> manager
# Para tolerar la caída de un manager se necesitan 3 managers (quórum Raft: 2 de 3).
source "$(dirname "$0")/comun.sh"
IP_NODO="${1:?Uso: $0 <ip-publica> [worker|manager]}"
ROL="${2:-worker}"
[[ "$ROL" == worker || "$ROL" == manager ]] || error "El rol debe ser worker o manager"

MANAGER=$(manager_ip)
MANAGER_PRIV=$(salida "$STACK_CLUSTER" ManagerIpPrivada)
TOKEN=$(en "$MANAGER" "docker swarm join-token -q $ROL")
info "Uniendo $IP_NODO como $ROL"
en "$IP_NODO" "docker swarm join --token $TOKEN $MANAGER_PRIV:2377"
HOST=$(en "$IP_NODO" hostname)
en "$MANAGER" "docker node update --label-add rol=app $HOST && docker node ls"
ok "Nodo $HOST agregado; Swarm reparte las nuevas réplicas en él (docker service update --force <servicio> para rebalancear)"
