#!/usr/bin/env bash
# Funciones y variables compartidas por los scripts del clúster.
# Variables que se pueden sobreescribir: PROYECTO, AWS_REGION, SSH_KEY, SSH_USER.
set -euo pipefail

export PROYECTO="${PROYECTO:-rys}"
export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="$AWS_REGION"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/${PROYECTO}-swarm.pem}"
SSH_USER="${SSH_USER:-ec2-user}"
STACK_CLUSTER="${PROYECTO}-cluster"
STACK_SERVICIOS="${PROYECTO}-servicios"
STACK_API="${PROYECTO}-api"
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

info()  { printf '\033[1;36m▶ %s\033[0m\n' "$*"; }
ok()    { printf '\033[1;32m✔ %s\033[0m\n' "$*"; }
error() { printf '\033[1;31m✖ %s\033[0m\n' "$*" >&2; exit 1; }

# salida <stack> <clave>  → valor de un Output de CloudFormation
salida() {
  aws cloudformation describe-stacks --stack-name "$1" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text
}

# IP pública actual de un nodo por su tag Name (las de los workers cambian al reiniciar el lab)
ip_publica_nodo() {
  aws ec2 describe-instances --filters "Name=tag:Name,Values=${PROYECTO}-$1" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text
}

SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=15 -o LogLevel=ERROR)
# en <ip> <comando...>  → ejecuta un comando remoto por SSH
en() { local ip="$1"; shift; ssh "${SSH_OPTS[@]}" "${SSH_USER}@${ip}" "$@"; }
# copiar <origen...> <ip>:<destino>
copiar() { scp -q "${SSH_OPTS[@]}" "$@"; }

manager_ip() { salida "$STACK_CLUSTER" ManagerIpPublica; }
