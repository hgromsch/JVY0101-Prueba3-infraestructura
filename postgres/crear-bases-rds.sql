-- Crea una base de datos por microservicio (patrón database-per-service) en Amazon RDS.
-- Idempotente: PostgreSQL no tiene CREATE DATABASE IF NOT EXISTS, se usa \gexec.
SELECT format('CREATE DATABASE %I', nombre)
FROM unnest(ARRAY['identidad_db','psicologos_db','agenda_db','talleres_db',
                  'pagos_db','clinico_db','notificaciones_db']) AS nombre
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = nombre)
\gexec

SELECT datname AS base_de_datos FROM pg_database WHERE datname LIKE '%\_db' ORDER BY 1;
