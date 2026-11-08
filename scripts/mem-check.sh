#!/bin/bash
# mem-check.sh - pamiec kontenerow: teraz, procesy (bez cache), szczyt od startu,
# limit i liczniki zdarzen limitu. Tylko czyta (cgroup v2).
#
# Uzycie:
#   ./mem-check.sh                  # wszystkie dzialajace kontenery
#   ./mem-check.sh pihole samba     # tylko wybrane
#   WARN_PCT=70 ./mem-check.sh      # prog ostrzezenia (domyslnie 80% limitu)
#
# Kolumny (MiB):
#   teraz   - memory.current (procesy + cache plikow)
#   anon    - pamiec samych procesow, bez cache; to ona grozi OOM
#   szczyt  - memory.peak od startu kontenera, RAZEM z cache. Przy limicie
#             dochodzi do limitu (cache wypelnia limit) - to normalne, nie blad
#   limit   - mem_limit z compose ("-" = brak)
#   anon%   - anon jako % limitu: wg tego ostrzezenie
#   max     - ile razy kontener doszedl do limitu (jadro odzyskalo cache; informacyjnie)
#   oomkill - ile razy jadro zabilo proces w kontenerze z braku pamieci
# !! = brak limitu, anon >= WARN_PCT limitu, oomkill > 0, OOMKilled, restarty.
#
# Uwaga: anon to wartosc biezaca, nie szczyt. Po zmianie limitow uruchamiaj
# skrypt co kilka dni: rosnace "max" przy malym anon jest OK, oomkill > 0 nie.

WARN_PCT="${WARN_PCT:-80}"

if [ $# -gt 0 ]; then
  NAMES=("$@")
else
  mapfile -t NAMES < <(docker ps --format '{{.Names}}' | sort)
fi

mib() { awk -v b="$1" 'BEGIN { printf "%.0f", b / 1048576 }'; }

cg_dir() {
  local id="$1" d
  for d in "/sys/fs/cgroup/system.slice/docker-${id}.scope" "/sys/fs/cgroup/docker/${id}"; do
    [ -d "$d" ] && { echo "$d"; return; }
  done
}

ev() { awk -v k="$2" '$1==k {print $2}' "$1/memory.events" 2>/dev/null; }

printf '%-28s %6s %6s %6s %6s %5s %5s %7s %4s  %s\n' kontener teraz anon szczyt limit anon% max oomkill rest uwagi
ISSUES=0
for n in "${NAMES[@]}"; do
  read -r id mem oom rc < <(docker inspect -f '{{.Id}} {{.HostConfig.Memory}} {{.State.OOMKilled}} {{.RestartCount}}' "$n" 2>/dev/null) \
    || { echo "$n: brak kontenera"; continue; }
  d=$(cg_dir "$id")
  if [ -z "$d" ]; then
    echo "$n: nie znaleziono cgroup (zatrzymany?)"
    continue
  fi
  cur=$(cat "$d/memory.current" 2>/dev/null || echo 0)
  peak=$(cat "$d/memory.peak" 2>/dev/null || echo 0)
  anon=$(awk '$1=="anon" {print $2}' "$d/memory.stat" 2>/dev/null)
  anon=${anon:-0}
  hits=$(ev "$d" max); hits=${hits:-0}
  kills=$(ev "$d" oom_kill); kills=${kills:-0}
  note=""
  if [ "$mem" = "0" ]; then
    lim="-"; pct="-"; note="!! brak limitu"
  else
    lim=$(mib "$mem")
    pct=$(awk -v a="$anon" -v m="$mem" 'BEGIN { printf "%.0f", a * 100 / m }')
    [ "$pct" -ge "$WARN_PCT" ] && note="!! procesy >= ${WARN_PCT}% limitu"
  fi
  [ "$kills" != "0" ] && note="$note !! oom_kill: $kills"
  [ "$oom" = "true" ] && note="$note !! OOMKilled"
  [ "$rc" != "0" ] && note="$note !! restarty: $rc"
  [ -n "$note" ] && ISSUES=$((ISSUES + 1))
  printf '%-28s %6s %6s %6s %6s %5s %5s %7s %4s  %s\n' "$n" "$(mib "$cur")" "$(mib "$anon")" "$(mib "$peak")" "$lim" "$pct" "$hits" "$kills" "$rc" "$note"
done
echo
echo "start kontenerow, czas UTC (szczyt i liczniki od tej chwili):"
for n in "${NAMES[@]}"; do
  printf '  %-28s %s\n' "$n" "$(docker inspect -f '{{.State.StartedAt}}' "$n" 2>/dev/null | cut -c1-16)"
done
echo
[ "$ISSUES" -eq 0 ] && echo "OK: bez uwag" || echo "Uwagi: $ISSUES (patrz kolumna uwagi)"
