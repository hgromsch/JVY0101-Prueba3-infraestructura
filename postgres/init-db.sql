-- Bases de datos de los microservicios de Respirar y Soltar.
-- Se ejecuta automáticamente la primera vez que arranca el contenedor Postgres
-- (docker-entrypoint-initdb.d). También puede ejecutarse a mano sobre un
-- PostgreSQL local:  psql -U postgres -f docker/postgres/init-db.sql

CREATE DATABASE identidad_db;
CREATE DATABASE psicologos_db;
CREATE DATABASE agenda_db;
CREATE DATABASE talleres_db;
CREATE DATABASE pagos_db;
CREATE DATABASE clinico_db;
CREATE DATABASE notificaciones_db;
