#!/usr/bin/env bash
# Carga los secrets de los pipelines en los repositorios de GitHub (requiere `gh auth login`).
# Repetir al iniciar cada sesión del Learner Lab: las credenciales de AWS cambian cada vez.
#   OWNER=<usuario-github> PREFIJO=JVY0101-Prueba3- ./configurar-secrets-github.sh
# Lee DB_PASSWORD, ORIGIN_SECRET, CLINICO_CRYPTO_KEY y PAGOS_WEBHOOK_SECRET del entorno.
source "$(dirname "$0")/comun.sh"
OWNER="${OWNER:?Defina OWNER (usuario de GitHub)}"
PREFIJO="${PREFIJO:-JVY0101-Prueba3-}"
command -v gh >/dev/null || error "Instale la CLI de GitHub: brew install gh && gh auth login"

AK=$(aws configure get aws_access_key_id); SK=$(aws configure get aws_secret_access_key); ST=$(aws configure get aws_session_token)
API_URL=$(salida "$STACK_API" ApiUrl)
API_KEY=$(aws apigateway get-api-key --api-key "$(salida "$STACK_API" ApiKeyClientesId)" --include-value --query value --output text)

poner() { gh secret set "$2" --repo "$OWNER/$1" --body "$3" >/dev/null && echo "  · $1 $2"; }
aws_creds() { poner "$1" AWS_ACCESS_KEY_ID "$AK"; poner "$1" AWS_SECRET_ACCESS_KEY "$SK"; poner "$1" AWS_SESSION_TOKEN "$ST"; }

for ms in ms-identidad ms-psicologos ms-agenda ms-talleres ms-pagos ms-clinico ms-notificaciones; do
  repo="${PREFIJO}${ms}"; aws_creds "$repo"
  poner "$repo" SWARM_HOST "$(manager_ip)"; poner "$repo" SWARM_SSH_KEY "$(cat "$SSH_KEY")"
  poner "$repo" API_URL "$API_URL"; poner "$repo" API_KEY "$API_KEY"
done
repo="${PREFIJO}fn-confirmacion-cita"; aws_creds "$repo"
repo="${PREFIJO}infraestructura"; aws_creds "$repo"
poner "$repo" SWARM_SSH_KEY "$(cat "$SSH_KEY")"
for s in DB_PASSWORD ORIGIN_SECRET CLINICO_CRYPTO_KEY PAGOS_WEBHOOK_SECRET; do poner "$repo" "$s" "${!s:?Defina $s}"; done
ok "Secrets cargados"
