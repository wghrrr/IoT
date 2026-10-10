#!/bin/bash
# ha-check.sh - czy Home Assistant jest gotowy do aktualizacji obrazu.
# Tylko czyta: wersje (dzialajaca, pobrana lokalnie, najnowsza stable),
# stan kontenera, bledy startu, naprawy (repairs), przestarzale API,
# custom_components, baza recordera, kopie zapasowe, a na koniec
# check_config konfiguracji w obrazie pobranym lokalnie (osobny, jednorazowy
# kontener, config tylko do odczytu, bez sieci - dzialajacy HA nie jest ruszany).
#
# Uzycie:
#   sudo ./ha-check.sh
#   sudo PULL=1 ./ha-check.sh       # najpierw docker pull obrazu (nie restartuje HA),
#                                   # zeby check_config sprawdzil wersje, ktora wejdzie
#   sudo CHECK=0 ./ha-check.sh      # bez check_config (szybciej)
#   sudo DB_CHECK=1 ./ha-check.sh   # dodatkowo PRAGMA quick_check bazy (kilka minut, czyta caly plik)
#
# Wynik zawiera nazwy encji i integracji - do rozmowy tak, do repo nie.
# Sekrety sa maskowane (klucze password/token/..., JWT, dlugie ciagi base64).

PULL="${PULL:-0}"
CHECK="${CHECK:-1}"
DB_CHECK="${DB_CHECK:-0}"
CT=homeassistant
BACKUP_DIR="${BACKUP_DIR:-/mnt/Dane4T/data4t/backup/docker_config}"

[ "$(id -u)" -eq 0 ] || { echo "Uruchom przez sudo" >&2; exit 1; }
docker inspect "$CT" >/dev/null 2>&1 || { echo "Brak kontenera $CT" >&2; exit 1; }

ISSUES=()
warn() { ISSUES+=("$*"); echo "  !! $*"; }
section() { echo; echo "=== $* ==="; }
M='s/((password|passwd|secret|token|credentials|bearer|authorization|api_?key)[^:= ]*["]?[:= ]+["]?)[^ ,}"]+/\1***/Ig; s/eyJ[A-Za-z0-9_.-]+/***JWT***/g; s/[A-Za-z0-9+\/_=-]{40,}/***B64***/g'
mask() { sed -E 's/\x1b\[[0-9;]*m//g' | sed -E "$M"; }

C=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/config"}}{{.Source}}{{end}}{{end}}' "$CT")
IMG=$(docker inspect -f '{{.Config.Image}}' "$CT")
[ -d "$C" ] || { echo "Nie znaleziono katalogu /config kontenera ($C)" >&2; exit 1; }

echo "================================================================"
echo " HA check - $(date '+%Y-%m-%d %H:%M:%S')"
echo " obraz: $IMG   config: $C"
echo "================================================================"

section "1. Wersje"
[ "$PULL" = "1" ] && { echo "docker pull $IMG ..."; docker pull -q "$IMG" || warn "pull nieudany"; }
RUN_ID=$(docker inspect -f '{{.Image}}' "$CT")
LOC_ID=$(docker image inspect -f '{{.Id}}' "$IMG" 2>/dev/null)
ver() { docker image inspect -f '{{index .Config.Labels "io.hass.version"}}' "$1" 2>/dev/null; }
RUN_VER=$(cat "$C/.HA_VERSION" 2>/dev/null)
LOC_VER=$(ver "$IMG")
NEW_VER=$(curl -fsm 10 https://version.home-assistant.io/stable.json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["homeassistant"]["default"])' 2>/dev/null)
echo "dziala:              ${RUN_VER:-?}"
echo "pobrany lokalnie:    ${LOC_VER:-?} ($IMG)"
echo "najnowsza stable:    ${NEW_VER:-? (brak odpowiedzi version.home-assistant.io)}"
[ "$RUN_ID" = "$LOC_ID" ] && echo "lokalny obraz = dzialajacy (upgrade.sh i tak zrobi pull)"
if [ -n "$NEW_VER" ] && [ -n "$LOC_VER" ] && [ "$NEW_VER" != "$LOC_VER" ]; then
  warn "upgrade.sh pobierze ${NEW_VER}, a nie lokalne ${LOC_VER} (tag ${IMG##*:})"
fi
if [ -n "$NEW_VER" ] && [ "${RUN_VER%.*}" != "${NEW_VER%.*}" ]; then
  warn "nowe wydanie miesieczne ${RUN_VER} -> ${NEW_VER}: przeczytaj 'Backward-incompatible changes' na home-assistant.io/blog"
fi

section "2. Kontener"
docker inspect -f 'start: {{.State.StartedAt}}  restarty: {{.RestartCount}}  OOMKilled: {{.State.OOMKilled}}  status: {{.State.Status}}' "$CT"
[ "$(docker inspect -f '{{.State.OOMKilled}}' "$CT")" = "true" ] && warn "HA byl zabity przez limit pamieci"
docker stats --no-stream --format 'pamiec: {{.MemUsage}} ({{.MemPerc}})  CPU: {{.CPUPerc}}' "$CT"
free -h | awk 'NR==2{print "host: dostepne " $7 " z " $2}'
df -h "$C" | awk 'NR==2{print "dysk z config: wolne " $4 " (" $5 " zajete)"}'

STARTED=$(docker inspect -f '{{.State.StartedAt}}' "$CT")
LOG=$(docker logs --since "$STARTED" "$CT" 2>&1 | mask)

section "3. Start HA: integracje, ktore sie nie uruchomily"
echo "$LOG" | grep -E 'Setup failed for|Error setting up entry|Unable to prepare setup|Error during setup of component|Config entry .* not ready|Setup of .* is taking longer|Unable to install package|Waiting for integrations' \
  | cut -c1-230 | tail -20
n=$(echo "$LOG" | grep -cE 'Setup failed for|Error setting up entry|Unable to prepare setup|Error during setup of component|Unable to install package')
echo "(nieudane setupy: $n)"
[ "$n" -eq 0 ] || warn "$n integracji nie uruchomilo sie od startu - napraw przed aktualizacja, inaczej nie odroznisz starych bledow od nowych"

section "4. Przestarzale API (co zniknie w kolejnych wersjach)"
echo "$LOG" | grep -iE 'deprecat|will be removed|stop working' | sed -E 's/^.*\] //' | cut -c1-200 \
  | sort | uniq -c | sort -rn | head -15

section "5. Naprawy (Ustawienia -> Naprawy), z rejestru"
R="$C/.storage/repairs.issue_registry"
if [ -f "$R" ]; then
  python3 - "$R" "${NEW_VER:-9999.99}" <<'PY' | sed -E 's/eyJ[A-Za-z0-9_.-]+/***JWT***/g'
import json, sys
d = json.load(open(sys.argv[1]))["data"]["issues"]
new = tuple(int(x) for x in sys.argv[2].split(".")[:2])
act = [i for i in d if not i.get("dismissed_version")]
pers = [i for i in act if i.get("is_persistent")]
other = [i for i in act if not i.get("is_persistent")]
print(f"trwale (aktywne do naprawy): {len(pers)}")
if other:
    print(f"nietrwale z rejestru: {len(other)} - aktywne tylko, jesli widac je w UI (Ustawienia -> System -> Naprawy):")
    for i in other: print(f"  ({i.get('domain','?')}) {i.get('issue_id','?')[:70]}")
for i in pers:
    b = i.get("breaks_in_ha_version") or ""
    flag = ""
    if b:
        try:
            flag = "  <-- PSUJE SIE W DOCELOWEJ WERSJI" if tuple(int(x) for x in b.split(".")[:2]) <= new else ""
        except ValueError: pass
    print(f"  {i.get('domain','?'):18s} {i.get('issue_id','?')[:70]:70s} {i.get('severity') or '':8s} {b}{flag}")
PY
else
  echo "brak $R"
fi

section "6. custom_components (najczestsza przyczyna problemow po aktualizacji)"
python3 - "$C"/custom_components/*/manifest.json <<'PY'
import json, sys
for p in sys.argv[1:]:
    try: m = json.load(open(p))
    except (OSError, ValueError): continue
    print(f"  {m.get('domain', '?'):22s} {m.get('version', '?'):12s} {m.get('documentation') or m.get('issue_tracker') or ''}")
PY
echo "(sprawdz w ich repo, czy najnowsze wydanie wspiera docelowa wersje HA)"

section "7. Baza recordera"
ls -lh "$C"/home-assistant_v2.db* 2>/dev/null | awk '{print "  " $5 "  " $NF}'
docker exec -i -e DB_CHECK="$DB_CHECK" "$CT" python3 - <<'PY'
import sqlite3, os
db = sqlite3.connect("file:/config/home-assistant_v2.db?mode=ro", uri=True)
print("schemat bazy:", db.execute("select schema_version from schema_changes order by change_id desc limit 1").fetchone()[0])
if os.environ.get("DB_CHECK") == "1":
    print("quick_check:", db.execute("pragma quick_check").fetchone()[0])
PY

section "8. Kopie zapasowe"
last=$(ls -t "$BACKUP_DIR"/docker-config-backup-*.zip 2>/dev/null | head -1)
if [ -n "$last" ]; then
  echo "backup-configs.sh: $(basename "$last") ($(du -h "$last" | cut -f1))"
  unzip -l "$last" 2>/dev/null | grep -q 'homeassistant_data/config/.storage/core.config_entries' \
    && echo "  zawiera .storage HA: tak" \
    || warn "ostatni zip nie zawiera .storage HA - zrob nowy backup-configs.sh przed aktualizacja"
  find "$last" -mmin +1440 | grep -q . && warn "ostatni backup-configs.sh starszy niz doba"
else
  warn "brak zipow backup-configs.sh w $BACKUP_DIR"
fi
b=$(ls -t "$C"/backups/*.tar 2>/dev/null | head -1)
[ -n "$b" ] && echo "kopia HA (UI): $(basename "$b") $(date -r "$b" '+%F %H:%M') ($(du -h "$b" | cut -f1))" || echo "kopia HA (UI): brak w $C/backups"

if [ "$CHECK" = "1" ]; then
  section "9. check_config w obrazie ${LOC_VER:-?} (osobny kontener, config :ro, bez sieci)"
  out=$(timeout 600 docker run --rm --network none --memory 768m --cpus 1 \
    -v "$C":/config:ro -v /etc/localtime:/etc/localtime:ro \
    --entrypoint python3 "$IMG" -m homeassistant --script check_config -c /config 2>&1)
  rc=$?
  echo "$out" | mask | grep -v -e 'SyntaxWarning' -e '^  return$' | tail -40
  [ "$rc" -eq 0 ] && echo "check_config: OK (kod 0, brak bledow)"
  [ "$rc" -eq 0 ] || warn "check_config w obrazie ${LOC_VER:-?} zakonczony kodem $rc (wyzej szczegoly)"
fi

echo
echo "================================================================"
echo " PODSUMOWANIE"
echo "================================================================"
if [ ${#ISSUES[@]} -eq 0 ]; then echo " brak uwag"; else printf ' - %s\n' "${ISSUES[@]}"; fi
