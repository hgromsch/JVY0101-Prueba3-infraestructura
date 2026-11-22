#!/usr/bin/env bash
# Crea las 7 bases de datos (una por microservicio) en Amazon RDS (IE5).
# RDS no es accesible desde Internet: el script corre psql en un contenedor efímero en el manager.
source "$(dirname "$0")/comun.sh"
: "${DB_PASSWORD:?Defina DB_PASSWORD}"
MANAGER=$(manager_ip)
DB_HOST=$(salida "$STACK_SERVICIOS" DbEndpoint)
info "Creando bases de datos en $DB_HOST"
copiar "$RAIZ/postgres/crear-bases-rds.sql" "${SSH_USER}@${MANAGER}:/tmp/crear-bases-rds.sql"
en "$MANAGER" "docker run --rm -e PGPASSWORD='$DB_PASSWORD' -v /tmp/crear-bases-rds.sql:/sql/init.sql:ro postgres:16-alpine \
  psql -h $DB_HOST -U respirar -d postgres -v ON_ERROR_STOP=1 -f /sql/init.sql"
ok "Bases de datos listas"
