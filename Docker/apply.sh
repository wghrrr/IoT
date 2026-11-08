#!/bin/bash
# Uzycie: ./apply.sh <nazwa_folderu> [usluga ...]
#   np. ./apply.sh pi-hole
#       ./apply.sh rpi-monitoring pihole-exporter
#
# Stosuje zmiany z docker-compose.yml (limity, porty, zmienne) BEZ pobierania
# nowych obrazow - w przeciwienstwie do upgrade.sh. "docker compose up -d"
# odtwarza tylko kontenery, ktorych konfiguracja sie zmienila (krotki restart
# tych kontenerow), pozostale zostaja nietkniete.
# Zatrzymanej uslugi nie uruchamia (tak jak upgrade.sh); wymus: START=1.
# Przed i po pokazuje limity pamieci i CPU kontenerow uslugi.
set -euo pipefail

DOCKER_DIR="${DOCKER_DIR:-$HOME/Docker}"
NAME="${1:?Podaj nazwe folderu, np. pi-hole}"
shift
DIR="${DOCKER_DIR}/${NAME}"

[ -d "$DIR" ] || { echo "Brak katalogu ${DIR}" >&2; exit 1; }
cd "$DIR"

docker compose config -q

limits() {
  local ids
  ids=$(docker compose ps -q "$@")
  [ -z "$ids" ] && { echo "  (brak dzialajacych kontenerow)"; return; }
  # shellcheck disable=SC2086
  docker inspect -f '  {{.Name}}: pamiec={{.HostConfig.Memory}} B, cpus={{.HostConfig.NanoCpus}} (1e9 = 1 CPU), start={{.State.StartedAt}}' $ids \
    | sed 's#  /#  #'
}

if [ -z "$(docker compose ps -q)" ] && [ "${START:-0}" != "1" ]; then
  echo "${NAME}: brak dzialajacych kontenerow - nic nie stosuje (START=1 wymusza uruchomienie)."
  exit 0
fi

echo "Przed:"
limits "$@"
docker compose up -d --no-build "$@"
echo "Po:"
limits "$@"
