# Respirar y Soltar — Infraestructura (EP3 · JVY0101)

Infraestructura como código y clúster **Docker Swarm** del sistema de agendamiento de terapia
**Respirar y Soltar**. Autor: Heinrich Gromsch Sanz (trabajo individual).

Este repositorio contiene todo lo necesario para levantar el sistema en **AWS** (Learner Lab, `us-east-1`)
y en local:

| Ruta | Qué es |
|---|---|
| `docker-compose.yml` | Stack de Swarm: 7 microservicios + Redis + edge nginx + visualizador (réplicas, límites, rolling update, secretos, red overlay cifrada) |
| `docker-compose.override.yml` | Ajustes solo para `docker compose up` local (build, PostgreSQL local, puertos 8081-8087) |
| `edge/nginx.conf` | Punto de entrada del clúster: enruta por prefijo y rechaza lo que no venga del API Gateway |
| `cloudformation/01-cluster-swarm.yaml` | 3 EC2 (1 manager + 2 workers) en 2 zonas, grupo de seguridad, IP elástica |
| `cloudformation/02-servicios-cloud.yaml` | RDS PostgreSQL, SQS + DLQ, S3 (comprobantes y artefactos), ECR (7 repos) |
| `cloudformation/03-api-gateway.yaml` | API Gateway REST: API keys, plan de uso (throttling + cuota), cabecera secreta hacia el edge |
| `scripts/` | Provisión, inicialización del Swarm, nodos, BD, despliegue, escalado, estado y limpieza |
| `.github/workflows/infraestructura.yml` | Pipeline: validar → provisionar → configurar → desplegar → prueba de humo |

Repositorios del sistema (clonarlos uno al lado del otro):

```
respirar-y-soltar-cloud/
├── ms-identidad/  ms-psicologos/  ms-agenda/  ms-talleres/
├── ms-pagos/      ms-clinico/     ms-notificaciones/
├── fn-confirmacion-cita/          ← función serverless (AWS Lambda)
└── rys-infraestructura/           ← este repositorio
```

## Arquitectura

```
                       Internet
                          │  HTTPS + x-api-key
                          ▼
            ┌───────────────────────────┐
            │ Amazon API Gateway (REST) │  API key · 50 req/s · 20.000/día · X-Origin-Verify
            └─────────────┬─────────────┘
                          │ HTTP :80 (IP elástica del manager)
   ┌──────────────────────┼──────────────── Docker Swarm (3 × t3.medium, us-east-1a / 1b) ─────┐
   │                      ▼                                                                    │
   │   edge (nginx ×2) ──► red overlay cifrada "backend" ──► ms-identidad ×2   ms-psicologos ×2 │
   │                                                       ms-agenda ×3 ─┐   ms-talleres ×2    │
   │                                                       ms-pagos ×2   │   ms-clinico ×2     │
   │                                                       ms-notificaciones ×2   redis ×1     │
   └───────────────────────────────────────────────────────────────┬────┼────────────────────────┘
                                                                   │    │ SendMessage (rol de la EC2)
                                   Amazon RDS PostgreSQL 16 ◄──────┘    ▼
                                   (7 bases, una por servicio)   Amazon SQS rys-citas-eventos ──► DLQ (3 intentos)
                                                                        │ event source mapping (lotes de 5)
                                                                        ▼
                                              AWS Lambda fn-confirmacion-cita ──► Amazon S3 (comprobante)
                                                       │
                                                       └──► API Gateway ──► ms-identidad / ms-psicologos / ms-notificaciones
```

**Requerimiento asíncrono que resuelve la cola** (RF-04 + RF-10): al reservar una cita, el paciente debe
recibir su confirmación, pero la reserva no puede esperar ni fallar porque el envío esté lento o caído.
`ms-agenda` (productor) publica `CITA_RESERVADA` / `CITA_REPROGRAMADA` / `CITA_CANCELADA` en SQS después
del commit; la Lambda (consumidor) genera el comprobante en S3 y registra la notificación. Si falla, el
mensaje se reintenta y a los 3 intentos pasa a la DLQ (con alarma de CloudWatch).

## Requisitos

- Cuenta AWS (AWS Academy Learner Lab) con las credenciales en `~/.aws/credentials` y AWS CLI v2
- Docker Desktop 24+ (con Compose v2) y Java 21 + Maven 3.9 para compilar
- `bash`, `ssh`, `scp`

## 1. Ejecutar en local (sin AWS)

```bash
cd rys-infraestructura
docker compose up -d --build          # construye las 7 imágenes y levanta todo
docker compose ps                     # esperar a que todos queden (healthy)
curl localhost:8083/api/citas         # cada microservicio en su puerto 8081..8087
curl -H 'X-Origin-Verify: local-dev' localhost:8080/agenda/api/citas   # a través del edge
docker compose down                   # detener (agregar -v para borrar los datos)
```

PostgreSQL local queda en el puerto **5433** (usuario/clave `respirar`).

## 2. Desplegar en AWS paso a paso

Todos los scripts son idempotentes (se pueden repetir). Los secretos se leen de variables de entorno:

```bash
export DB_PASSWORD='...' ORIGIN_SECRET='...' CLINICO_CRYPTO_KEY='...' PAGOS_WEBHOOK_SECRET='...'
# CLINICO_CRYPTO_KEY = 32 bytes en Base64:  openssl rand -base64 32

./scripts/01-provisionar.sh cluster     # EC2 + grupo de seguridad + IP elástica (+ par de llaves ~/.ssh/rys-swarm.pem)
./scripts/01-provisionar.sh servicios   # RDS, SQS + DLQ, S3, ECR  (RDS tarda ~8 min)
./scripts/02-iniciar-swarm.sh           # swarm init + join de los workers + etiquetas
./scripts/04-configurar-bd.sh           # crea las 7 bases de datos en RDS
./scripts/06-subir-imagenes.sh          # solo la primera vez (después lo hacen los pipelines)
./scripts/01-provisionar.sh api         # API Gateway apuntando a la IP elástica del manager
./scripts/05-desplegar-stack.sh         # secretos de Swarm + docker stack deploy
../fn-confirmacion-cita/scripts/desplegar.sh   # Lambda + disparador SQS
./scripts/estado.sh                     # nodos, servicios y dónde corre cada réplica
```

O bien, todo de una vez con el pipeline **Infraestructura** (GitHub Actions → *Run workflow*).

## 3. Administración del clúster Docker Swarm

### Inicializar (lo hace `02-iniciar-swarm.sh`)

```bash
# En el manager: anuncia su IP privada; los nodos se comunican por la VPC
docker swarm init --advertise-addr <IP_PRIVADA_MANAGER>
# Token para unir workers (o managers)
docker swarm join-token worker
docker swarm join-token manager
```

### Agregar un nodo **worker**

1. Crear una EC2 con Docker en la misma VPC y con el grupo de seguridad `rys-sg-cluster`
   (puertos 2377/tcp, 7946/tcp+udp, 4789/udp y ESP abiertos entre los nodos del grupo).
2. Ejecutar:
   ```bash
   ./scripts/03-agregar-nodo.sh <IP_PUBLICA_DEL_NODO> worker
   ```
   Equivale a `docker swarm join --token <TOKEN_WORKER> <IP_PRIVADA_MANAGER>:2377` en el nodo nuevo, más
   la etiqueta `rol=app` para que reciba microservicios.

### Agregar un nodo **manager** (alta disponibilidad del plano de control)

```bash
./scripts/03-agregar-nodo.sh <IP_PUBLICA_DEL_NODO> manager
```

Swarm usa consenso **Raft**: con 1 manager, si cae el manager los servicios siguen corriendo pero no se
pueden hacer cambios. Para tolerar la caída de un manager se necesitan **3** (quórum 2 de 3); siempre un
número impar. También se puede promover un worker existente: `docker node promote rys-worker-1`.

### Operación diaria

```bash
./scripts/estado.sh                         # docker node ls + docker stack services + docker stack ps
./scripts/escalar.sh ms-agenda 6            # docker service scale rys_ms-agenda=6
docker service logs -f rys_ms-agenda        # logs agregados de todas las réplicas (en el manager)
docker node update --availability drain rys-worker-2   # mantención: mueve sus tareas a otros nodos
docker node update --availability active rys-worker-2
ssh -i ~/.ssh/rys-swarm.pem -L 8090:localhost:8090 ec2-user@<IP_MANAGER>   # visualizador en http://localhost:8090
```

## 4. Decisiones técnicas (escalabilidad, disponibilidad, mantenibilidad)

| Decisión | Por qué |
|---|---|
| 3 nodos en **2 zonas de disponibilidad** y `placement.preferences: spread: node.labels.zona` | Si cae una zona o un nodo, quedan réplicas vivas de cada servicio |
| **2 réplicas** por servicio, **3** en `ms-agenda` | Es el servicio con más tráfico (reservas en horario punta); todos sin estado → escalan horizontalmente |
| Estado fuera de los contenedores: **RDS** (datos), **Redis** (bloqueos de horario y cupos) | Cualquier réplica atiende cualquier petición; escalar no rompe las invariantes (anti doble reserva) |
| `update_config: order: start-first` + `failure_action: rollback` + HEALTHCHECK | Despliegues sin corte; si la versión nueva no queda *healthy*, Swarm vuelve sola a la anterior |
| `restart_policy: any` + HEALTHCHECK en cada imagen | Autorreparación: una réplica colgada se reemplaza |
| Límites de CPU/memoria por servicio y JVM con `MaxRAMPercentage` | Un servicio no puede dejar sin recursos a los demás del mismo nodo |
| Red overlay **cifrada** y **secretos de Swarm** (`/run/secrets`) | Tráfico entre nodos cifrado; claves fuera de las imágenes, del repo y de las variables de entorno |
| Solo el **edge** publica un puerto (80) y exige `X-Origin-Verify` | El backend solo es alcanzable a través del API Gateway (API key, throttling, cuota) |
| **Cola SQS + DLQ** entre agenda y la Lambda | Desacopla, absorbe picos y no pierde confirmaciones si el consumidor falla |
| Todo versionado (CloudFormation, compose, scripts) + pipelines | El clúster se recrea igual desde cero; cada cambio queda trazado a un commit |

## 5. Pipeline de infraestructura y secrets

| Secret de GitHub | Uso |
|---|---|
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` | Credenciales del Learner Lab (**se renuevan en cada sesión del lab**) |
| `SWARM_SSH_KEY` | Contenido de `~/.ssh/rys-swarm.pem` |
| `DB_PASSWORD`, `ORIGIN_SECRET`, `CLINICO_CRYPTO_KEY`, `PAGOS_WEBHOOK_SECRET` | Secretos de la aplicación (se convierten en secretos de Swarm) |

`scripts/configurar-secrets-github.sh` los carga en todos los repositorios con la CLI `gh`.

## 6. Limpieza

```bash
./scripts/destruir.sh   # borra los stacks fn, api, servicios y cluster (pide confirmación)
```
