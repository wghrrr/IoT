#!/bin/bash
# Sprawdza dla wszystkich projektow docker compose w $DOCKER_DIR (domyslnie
# ~/Docker), czy dzialajace kontenery maja dostepny nowszy obraz w rejestrze.
#
# NIE dotyka zadnych kontenerow - pobiera obrazy ("docker compose pull",
# czyli calosc, nie tylko manifest) i porownuje ID obrazu z tym, co dziala.
# Decyzja o samym upgrade zostaje reczna (patrz upgrade.sh); pobrany obraz
# upgrade.sh juz tylko podmienia.
#
# Domyslnie pomija uslugi zatrzymane (zaden kontener nie dziala): ich pull
# trwa i zajmuje miejsce na dysku, a porownac i tak nie ma z czym.
#   ALL=1 ./check-updates.sh          # pobierz tez obrazy zatrzymanych uslug
#   PULL_TIMEOUT=600 ./check-updates.sh   # limit na pull jednej uslugi (s)
#
# Wymaga: jq (sudo apt install -y jq)
set -euo pipefail

DOCKER_DIR="${DOCKER_DIR:-$HOME/Docker}"
PULL_TIMEOUT="${PULL_TIMEOUT:-300}"

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
    if [ -z "$(docker compose ps -q 2>/dev/null)" ] && [ "${ALL:-0}" != "1" ]; then
      echo "    zatrzymana - pomijam (ALL=1 pobiera tez obrazy zatrzymanych)" >&2
      exit 0
    fi
    rc=0
    pull_ok=1
    pull_log=$(mktemp)
    if [ -t 2 ]; then
      # terminal: pasek postepu compose (bledy widac od razu na ekranie);
      # --foreground, zeby Ctrl+C dochodzilo do docker compose
      echo "    pobieranie obrazow (max ${PULL_TIMEOUT}s):" >&2
      timeout --foreground "$PULL_TIMEOUT" docker compose pull >&2 || rc=$?
    else
      # przekierowanie do pliku/potoku: cicho, bledy z logu nizej
      timeout "$PULL_TIMEOUT" docker compose pull -q >"$pull_log" 2>&1 || rc=$?
    fi
    [ "$rc" -eq 0 ] || pull_ok=0
    if [ "$rc" -eq 124 ]; then
      echo "    TIMEOUT (${PULL_TIMEOUT}s) przy pull dla ${dir} - status ponizej NIEPEWNY" >&2
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
        if [ -n "$running_ver" ] && [ -n "$latest_ver" ] && [ "$running_ver" != "$latest_ver" ]; then
          status="DOSTEPNY UPGRADE (${running_ver} -> ${latest_ver})"
        else
          status="DOSTEPNY UPGRADE (${running_id:7:12} -> ${latest_id:7:12})"
        fi
      elif [ "$pull_ok" = "1" ]; then
        status="aktualny"
      else
        status="? (pull nieukonczony - porownanie ze starym obrazem)"
      fi
      printf "%-25s %-45s %s\n" "$name" "$image" "$status"
    done
  )
done
