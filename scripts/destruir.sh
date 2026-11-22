#!/usr/bin/env bash
# Elimina TODA la infraestructura de AWS del proyecto (para no gastar presupuesto del lab).
source "$(dirname "$0")/comun.sh"
read -r -p "¿Eliminar los stacks fn, api, servicios y cluster de $PROYECTO? (escriba si) " r
[[ "$r" == si ]] || exit 1
for s in "${PROYECTO}-fn-confirmacion-cita" "$STACK_API" "$STACK_SERVICIOS" "$STACK_CLUSTER"; do
  for b in $(aws cloudformation describe-stack-resources --stack-name "$s" --query "StackResources[?ResourceType=='AWS::S3::Bucket'].PhysicalResourceId" --output text 2>/dev/null); do
    aws s3 rm "s3://$b" --recursive >/dev/null || true
  done
  info "Eliminando $s"; aws cloudformation delete-stack --stack-name "$s"
  aws cloudformation wait stack-delete-complete --stack-name "$s" || true
done
ok "Infraestructura eliminada (el par de llaves ${PROYECTO}-swarm se conserva)"
