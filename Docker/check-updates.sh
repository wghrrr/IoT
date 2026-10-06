#!/bin/bash
# Sprawdza dla wszystkich projektow docker compose w $DOCKER_DIR (domyslnie
# ~/Docker), czy dzialajace kontenery maja dostepny nowszy obraz w rejestrze.
#
# NIE dotyka zadnych kontenerow - tylko pobiera aktualne manifesty
# ("docker compose pull") i porownuje ID obrazu z tym co faktycznie dziala.
# Decyzja o samym upgrade zostaje reczna (patrz upgrade.sh).
#
# Wymaga: jq (sudo apt install -y jq)
set -euo pipefail

DOCKER_DIR="${DOCKER_DIR:-$HOME/Docker}"

printf "%-25s %-45s %s\n" "KONTENER" "OBRAZ" "STATUS"
printf -- '-%.0s' $(seq 1 95); echo

for dir in "$DOCKER_DIR"/*/; do
  compose_file=""
  [ -f "${dir}docker-compose.yml" ] && compose_file="${dir}docker-compose.yml"
  [ -f "${dir}docker-compose.yaml" ] && compose_file="${dir}docker-compose.yaml"
  [ -n "$compose_file" ] || continue

  (
    cd "$dir"
    echo "==> ${dir}" >&2
    rc=0
    pull_log=$(mktemp)
    timeout 60 docker compose pull -q >"$pull_log" 2>&1 || rc=$?
    if [ "$rc" -eq 124 ]; then
      echo "    TIMEOUT (60s) przy pull dla ${dir}" >&2
    elif [ "$rc" -ne 0 ]; then
      echo "    BLAD pull (kod ${rc}) dla ${dir} - status ponizej moze byc NIEAKTUALNY:" >&2
      sed 's/^/      /' "$pull_log" >&2
    fi
    rm -f "$pull_log"

    # Obraz docelowy bierzemy z "docker compose config" (zawsze pelny tag),
    # a NIE z "docker compose ps" - to drugie po ponownym pullu tagu potrafi
    # zwrocic samo ID starego, juz "osieroconego" obrazu (bez repo:tag), co
    # sprawia ze porownanie ponizej zawsze wychodzi "aktualny".
    declare -A service_image=()
    while IFS='=' read -r svc img; do
      [ -n "$svc" ] && service_image["$svc"]="$img"
    done < <(docker compose config --format json 2>/dev/null | jq -r '.services | to_entries[] | "\(.key)=\(.value.image // "")"')

    docker compose ps --format json 2>/dev/null | jq -c '.' 2>/dev/null | while read -r row; do
      name=$(echo "$row" | jq -r '.Name // empty')
      service=$(echo "$row" | jq -r '.Service // empty')
      [ -n "$name" ] || continue

      image="${service_image[$service]:-}"
      [ -n "$image" ] || image=$(echo "$row" | jq -r '.Image // empty')

      running_id=$(docker inspect --format '{{.Image}}' "$name" 2>/dev/null || echo "")
      latest_id=$(docker image inspect --format '{{.Id}}' "$image" 2>/dev/null || echo "")

      if [ -z "$running_id" ] || [ -z "$latest_id" ]; then
        status="? (brak danych)"
      elif [ "$running_id" != "$latest_id" ]; then
        version_label='{{index .Config.Labels "org.opencontainers.image.version"}}'
        running_ver=$(docker image inspect --format "$version_label" "$running_id" 2>/dev/null || echo "")
        latest_ver=$(docker image inspect --format "$version_label" "$latest_id" 2>/dev/null || echo "")
        if [ -n "$running_ver" ] && [ -n "$latest_ver" ]; then
          status="DOSTEPNY UPGRADE (${running_ver} -> ${latest_ver})"
        else
          status="DOSTEPNY UPGRADE (${running_id:7:12} -> ${latest_id:7:12})"
        fi
      else
        status="aktualny"
      fi
      printf "%-25s %-45s %s\n" "$name" "$image" "$status"
    done
  )
done
