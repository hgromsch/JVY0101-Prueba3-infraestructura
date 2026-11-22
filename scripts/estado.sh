#!/usr/bin/env bash
# Estado del clúster: nodos, servicios del stack y dónde corre cada réplica.
source "$(dirname "$0")/comun.sh"
en "$(manager_ip)" "docker node ls; echo; docker stack services rys; echo; \
  docker stack ps rys --filter desired-state=running --format 'table {{.Name}}\t{{.Node}}\t{{.CurrentState}}'"
