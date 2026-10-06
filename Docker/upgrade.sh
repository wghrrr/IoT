#!/bin/bash
# Uzycie: ./upgrade.sh <nazwa_folderu>   np. ./upgrade.sh homeassistant
#
# Zastepuje wzorzec "docker stop X && docker rm -f X && docker-compose pull
# && docker-compose up -d" powtarzany w poszczegolnych katalogach.
# "docker compose up -d" samo wykrywa zmiane obrazu i podmienia tylko
# ten kontener, ktory faktycznie ma nowszy obraz - recznego stop/rm -f
# nie trzeba juz robic. Jesli obraz sie nie zmienil, to jest no-op (zero
# przestoju).
#
# Stos z sekcja "build:" (np. lemp) jest przebudowywany (--build).
# Zatrzymana usluga (zaden kontener nie dziala) nie jest uruchamiana - tylko pull.
# Na koniec usuwane sa nieuzywane obrazy; PRUNE=0 ./upgrade.sh X pomija ten krok.
set -euo pipefail

DOCKER_DIR="${DOCKER_DIR:-$HOME/Docker}"
NAME="${1:?Podaj nazwe folderu, np. homeassistant (patrz check-updates.sh)}"
DIR="${DOCKER_DIR}/${NAME}"

[ -d "$DIR" ] || { echo "Brak katalogu ${DIR}" >&2; exit 1; }

cd "$DIR"
docker compose pull --ignore-buildable

# Zatrzymanej uslugi nie uruchamiamy - tylko pobrany obraz czeka na nastepny start.
if [ -z "$(docker compose ps -q)" ]; then
  echo "${NAME}: brak dzialajacych kontenerow - pobrano obrazy, usluga zostaje zatrzymana."
  exit 0
fi
if docker compose config | grep -qE '^\s+build:'; then
  docker compose up -d --build
else
  docker compose up -d
fi

if [ "${PRUNE:-1}" = "1" ]; then
  docker image prune -f
fi
