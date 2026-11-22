#!/usr/bin/env bash
# Inicializa el clúster Docker Swarm (IE7). Idempotente: se puede ejecutar de nuevo sin romper nada.
#  1. espera que Docker esté instalado en los 3 nodos (lo instala el user data de la EC2)
#  2. docker swarm init en el manager (anunciando su IP privada)
#  3. une los 2 workers con el token de worker
#  4. etiqueta los nodos: zona (AZ), rol=app y datos=true (manager, donde vive el volumen de Redis)
source "$(dirname "$0")/comun.sh"

MANAGER=$(manager_ip)
MANAGER_PRIV=$(salida "$STACK_CLUSTER" ManagerIpPrivada)
WORKERS=("$(ip_publica_nodo worker-1)" "$(ip_publica_nodo worker-2)")

esperar_docker() {
  local ip="$1"
  for i in $(seq 1 40); do
    if en "$ip" 'test -f /var/lib/cloud/instance/docker-listo && docker info >/dev/null 2>&1'; then
      ok "Docker listo en $ip"; return 0
    fi
    sleep 10
  done
  error "Docker no quedó listo en $ip"
}

for ip in "$MANAGER" "${WORKERS[@]}"; do esperar_docker "$ip"; done

if [[ "$(en "$MANAGER" "docker info --format '{{.Swarm.LocalNodeState}}'")" != active ]]; then
  info "docker swarm init en el manager ($MANAGER_PRIV)"
  en "$MANAGER" "docker swarm init --advertise-addr $MANAGER_PRIV --default-addr-pool 10.20.0.0/16"
else
  ok "El manager ya es parte de un Swarm"
fi

TOKEN_WORKER=$(en "$MANAGER" 'docker swarm join-token -q worker')
for ip in "${WORKERS[@]}"; do
  if [[ "$(en "$ip" "docker info --format '{{.Swarm.LocalNodeState}}'")" != active ]]; then
    info "Uniendo worker $ip al clúster"
    en "$ip" "docker swarm join --token $TOKEN_WORKER $MANAGER_PRIV:2377"
  else
    ok "El worker $ip ya está en el Swarm"
  fi
done

info "Etiquetando nodos"
en "$MANAGER" 'bash -s' <<'REMOTO'
set -e
TOKEN=$(curl -sX PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 60")
for nodo in $(docker node ls -q); do
  nombre=$(docker node inspect "$nodo" --format '{{.Description.Hostname}}')
  zona=$(aws ec2 describe-instances --region us-east-1 --filters "Name=tag:Name,Values=$nombre" "Name=instance-state-name,Values=running" \
          --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' --output text 2>/dev/null || echo desconocida)
  docker node update --label-add rol=app --label-add zona="$zona" "$nodo" >/dev/null
done
docker node update --label-add datos=true "$(docker node ls --filter role=manager -q | head -1)" >/dev/null
docker node ls
REMOTO
ok "Clúster Swarm listo"
