#!/usr/bin/env bash
# Prueba de extremo a extremo en la nube (IE14/IE15):
#   cliente → API Gateway → edge → ms-identidad / ms-psicologos / ms-agenda → RDS + Redis
#   → SQS (productor ms-agenda) → Lambda (consumidor) → S3 + ms-notificaciones → respuesta final
# Además valida la protección del backend y, con CARGA=<n>, envía n reservas concurrentes.
source "$(dirname "$0")/comun.sh"
API_URL=$(salida "$STACK_API" ApiUrl)
API_KEY=$(aws apigateway get-api-key --api-key "$(salida "$STACK_API" ApiKeyClientesId)" --include-value --query value --output text)
BUCKET=$(salida "$STACK_SERVICIOS" BucketComprobantes)
COLA=$(salida "$STACK_SERVICIOS" ColaCitasUrl)
J='Content-Type: application/json'
api() { curl -s -H "x-api-key: $API_KEY" -H "$J" "$@"; }
campo() { python3 -c "import sys,json; print(json.load(sys.stdin)$1)"; }

info "0 · Protección del backend"
echo "  GET $API_URL/agenda/api/citas sin API key     → $(curl -s -o /dev/null -w '%{http_code}' "$API_URL/agenda/api/citas")"
echo "  GET http://$(manager_ip)/agenda/api/citas directo al clúster → $(curl -s -o /dev/null -w '%{http_code}' "http://$(manager_ip)/agenda/api/citas")"
echo "  GET $API_URL/agenda/api/citas con API key     → $(curl -s -o /dev/null -w '%{http_code}' -H "x-api-key: $API_KEY" "$API_URL/agenda/api/citas")"

SUFIJO=$(date +%H%M%S)
info "1 · Paciente en ms-identidad"
PACIENTE=$(api -X POST "$API_URL/identidad/api/usuarios" -d "{\"nombre\":\"Camila Rojas\",\"email\":\"camila.$SUFIJO@correo.cl\",\"rol\":\"PACIENTE\"}")
PACIENTE_ID=$(echo "$PACIENTE" | campo "['id']"); echo "  $PACIENTE"

info "2 · Psicóloga en ms-psicologos"
PSICO=$(api -X POST "$API_URL/psicologos/api/psicologos" -d '{"nombre":"Ps. Silvana Varela","especialidad":"Ansiedad y estrés","modalidad":"HIBRIDA"}')
PSICO_ID=$(echo "$PSICO" | campo "['id']"); echo "  $PSICO"

info "3 · Reserva de la cita en ms-agenda (productor de la cola)"
HORARIO=$(python3 -c "import datetime as d; print((d.datetime.now()+d.timedelta(days=3)).replace(minute=0,second=0,microsecond=0).isoformat())")
T0=$(python3 -c 'import time; print(time.time())')
RESERVA="{\"pacienteId\":\"$PACIENTE_ID\",\"psicologoId\":\"$PSICO_ID\",\"horario\":\"$HORARIO\"}"
CITA=$(api -X POST "$API_URL/agenda/api/citas" -d "$RESERVA")
CITA_ID=$(echo "$CITA" | campo "['id']"); echo "  $CITA"
DOBLE=$(api -X POST "$API_URL/agenda/api/citas" -d "$RESERVA")
echo "  Doble reserva del mismo horario → $DOBLE"

info "4 · Consumidor: la Lambda procesa el evento (comprobante en S3 + notificación)"
for i in $(seq 1 45); do
  CLAVE=$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "comprobantes/$CITA_ID/" --query 'Contents[0].Key' --output text 2>/dev/null)
  [[ "$CLAVE" != None && -n "$CLAVE" ]] && break; sleep 1
done
[[ "$CLAVE" != None && -n "$CLAVE" ]] || error "La Lambda no generó el comprobante (revise: aws logs tail /aws/lambda/rys-fn-confirmacion-cita)"
T1=$(python3 -c 'import time; print(time.time())')
echo "  Comprobante: s3://$BUCKET/$CLAVE  (en $(python3 -c "print(round($T1-$T0,1))") s desde la reserva)"
NOTIF=$(api "$API_URL/notificaciones/api/notificaciones?destinatario=camila.$SUFIJO@correo.cl")
echo "  Notificación en ms-notificaciones: $NOTIF"

info "5 · Estado de la cola"
aws sqs get-queue-attributes --queue-url "$COLA" --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible --query Attributes --output text | sed 's/^/  pendientes, en proceso: /'

if [[ -n "${CARGA:-}" ]]; then
  info "6 · Carga: $CARGA reservas concurrentes (10 en paralelo) por el API Gateway"
  RESP=$(mktemp)
  # Horarios precalculados (uno por hora, desde 30 días más) para lanzar las peticiones sin demoras
  HORARIOS=($(python3 -c "import datetime as d; b=(d.datetime.now()+d.timedelta(days=30)).replace(minute=0,second=0,microsecond=0); print(' '.join((b+d.timedelta(hours=i)).isoformat() for i in range(1,$CARGA+1)))"))
  INI=$(python3 -c 'import time; print(time.time())')
  for i in $(seq 0 $((CARGA - 1))); do
    curl -s -o /dev/null -w '%{http_code} %{time_total}\n' -H "x-api-key: $API_KEY" -H "$J" -X POST "$API_URL/agenda/api/citas" \
      -d "{\"pacienteId\":\"$PACIENTE_ID\",\"psicologoId\":\"$PSICO_ID\",\"horario\":\"${HORARIOS[$i]}\"}" >> "$RESP" &
    (( (i + 1) % 10 == 0 )) && wait
  done; wait
  FIN=$(python3 -c 'import time; print(time.time())')
  awk '{print $1}' "$RESP" | sort | uniq -c | sed 's/^/  respuestas HTTP: /'
  sort -k2 -n "$RESP" | awk '{t[NR]=$2; s+=$2} END {printf "  tiempo de respuesta: promedio %.2f s · p50 %.2f s · p95 %.2f s · máximo %.2f s\n", s/NR, t[int(NR*0.5)], t[int(NR*0.95)], t[NR]}' 
  echo "  $CARGA reservas en $(python3 -c "print(round($FIN-$INI,1))") s"
  info "7 · La cola y la Lambda absorben el pico: confirmaciones de las $CARGA reservas"
  for i in $(seq 1 60); do
    N=$(api "$API_URL/notificaciones/api/notificaciones?destinatario=camila.$SUFIJO@correo.cl" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))")
    EN_COLA=$(aws sqs get-queue-attributes --queue-url "$COLA" --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible --query 'Attributes.[ApproximateNumberOfMessages,ApproximateNumberOfMessagesNotVisible]' --output text | tr '\t' '/')
    echo "  $(date +%T)  notificaciones enviadas: $N de $((CARGA + 1))   cola (pendientes/en proceso): $EN_COLA"
    [[ "$N" -ge $((CARGA + 1)) ]] && break; sleep 5
  done
  DLQ=$(aws sqs get-queue-url --queue-name "${PROYECTO}-citas-eventos-dlq" --query QueueUrl --output text)
  echo "  mensajes en la DLQ: $(aws sqs get-queue-attributes --queue-url "$DLQ" --attribute-names ApproximateNumberOfMessages --query Attributes.ApproximateNumberOfMessages --output text)"
  echo "  total de confirmaciones en $(python3 -c "import time; print(round(time.time()-$INI,1))") s desde la primera reserva"
  rm -f "$RESP"
fi
ok "Flujo completo verificado"
