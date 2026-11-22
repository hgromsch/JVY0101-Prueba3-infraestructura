#!/usr/bin/env bash
# Provisiona la infraestructura con CloudFormation (IE5). Idempotente: si no hay cambios, no hace nada.
#   ./01-provisionar.sh cluster     → 3 EC2 (manager + 2 workers), grupo de seguridad, IP elástica
#   ./01-provisionar.sh servicios   → RDS PostgreSQL, SQS + DLQ, S3, ECR
#   ./01-provisionar.sh api         → API Gateway con API key, throttling y cuota
#   ./01-provisionar.sh todo        → los tres, en orden
# Requiere: DB_PASSWORD (servicios) y ORIGIN_SECRET (api) en el entorno.
source "$(dirname "$0")/comun.sh"
QUE="${1:-todo}"

VPC_ID=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
SUBNET_A=$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC_ID" Name=availability-zone,Values="${AWS_REGION}a" Name=default-for-az,Values=true --query 'Subnets[0].SubnetId' --output text)
SUBNET_B=$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC_ID" Name=availability-zone,Values="${AWS_REGION}b" Name=default-for-az,Values=true --query 'Subnets[0].SubnetId' --output text)

desplegar() { # desplegar <stack> <plantilla> [parametros...]
  local stack="$1" plantilla="$2"; shift 2
  info "CloudFormation: $stack ($plantilla)"
  aws cloudformation deploy --stack-name "$stack" --template-file "$RAIZ/cloudformation/$plantilla" \
    --no-fail-on-empty-changeset --tags Proyecto="$PROYECTO" Curso=JVY0101-EP3 \
    --parameter-overrides Proyecto="$PROYECTO" "$@"
  ok "$stack listo"
}

if [[ "$QUE" == cluster || "$QUE" == todo ]]; then
  # Par de llaves SSH del clúster (se guarda local y va como secret SWARM_SSH_KEY del pipeline)
  if ! aws ec2 describe-key-pairs --key-names "${PROYECTO}-swarm" >/dev/null 2>&1; then
    info "Creando par de llaves ${PROYECTO}-swarm → $SSH_KEY"
    mkdir -p "$(dirname "$SSH_KEY")"
    aws ec2 create-key-pair --key-name "${PROYECTO}-swarm" --key-type ed25519 \
      --query KeyMaterial --output text > "$SSH_KEY"
    chmod 600 "$SSH_KEY"
  fi
  desplegar "$STACK_CLUSTER" 01-cluster-swarm.yaml KeyName="${PROYECTO}-swarm" \
    VpcId="$VPC_ID" SubnetA="$SUBNET_A" SubnetB="$SUBNET_B"
fi

if [[ "$QUE" == servicios || "$QUE" == todo ]]; then
  : "${DB_PASSWORD:?Defina DB_PASSWORD}"
  desplegar "$STACK_SERVICIOS" 02-servicios-cloud.yaml VpcId="$VPC_ID" SubnetA="$SUBNET_A" \
    SubnetB="$SUBNET_B" DbPassword="$DB_PASSWORD"
fi

if [[ "$QUE" == api || "$QUE" == todo ]]; then
  : "${ORIGIN_SECRET:?Defina ORIGIN_SECRET}"
  desplegar "$STACK_API" 03-api-gateway.yaml ManagerIp="$(manager_ip)" OriginSecret="$ORIGIN_SECRET"
  # Un despliegue nuevo de la API para que la etapa prod tome cualquier cambio de integración
  API_ID=$(salida "$STACK_API" ApiId)
  aws apigateway create-deployment --rest-api-id "$API_ID" --stage-name prod \
    --description "Despliegue desde 01-provisionar.sh" >/dev/null
  ok "API publicada en $(salida "$STACK_API" ApiUrl)"
fi
