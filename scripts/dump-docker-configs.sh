#!/bin/bash
# dump-docker-configs.sh - wypisuje tresc wszystkich docker-compose.yml/.yaml z ~/Docker
#
# Uzycie:
#   ./dump-docker-configs.sh                # domyslnie ~/Docker
#   ./dump-docker-configs.sh /inna/sciezka
#
# Pozwala zweryfikowac aktualny stan wszystkich sciezek wolumenow na raz.
# Compose nie zawiera sekretow (sa w .env), ale moze zawierac sciezki i porty.

DOCKER_DIR="${1:-$HOME/Docker}"

for f in "$DOCKER_DIR"/*/docker-compose.y*ml; do
  [ -f "$f" ] || continue
  echo "===== $f ====="
  cat "$f"
  echo
done
