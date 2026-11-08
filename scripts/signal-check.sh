#!/bin/bash
# signal-check.sh - przeglad bramki Signal (kontener "signal", signal-cli-rest-api).
# Domyslnie tylko czyta. Na koncu PODSUMOWANIE z lista rzeczy do sprawdzenia.
# Numery telefonow w wyniku sa maskowane (+48*****123), wiec wynik mozna wkleic do rozmowy.
#
# Uzycie:
#   ./signal-check.sh                          # przeglad (bez sudo; kopie zapasowe moga wymagac sudo)
#   sudo ./signal-check.sh                     # pelny przeglad, tez zawartosc archiwow backupu
#   SINCE=72h ./signal-check.sh                # zakres logow (domyslnie 24h)
#   SEND_TO='+48XXXXXXXXX' ./signal-check.sh   # dodatkowo wysyla wiadomosc testowa (ZMIENIA: wysyla)
#
# Sprawdza: kontener (stan, restarty, OOM, obraz), API (/v1/health, /v1/about, tryb),
# konto (zarejestrowane), port (tylko 127.0.0.1), limity i pamiec, uprawnienia i
# montowania (bez docker.sock, bez privileged), katalog danych (na dysku, wlasciciel,
# 700, nic czytelnego dla innych), compose i .env, logi (bledy), kopie zapasowe.

NAME="${NAME:-signal}"
SINCE="${SINCE:-24h}"
DOCKER_DIR="${DOCKER_DIR:-$HOME/Docker}"
[ -n "${SUDO_USER:-}" ] && DOCKER_DIR="$(getent passwd "$SUDO_USER" | cut -d: -f6)/Docker"
SVC_DIR="$DOCKER_DIR/signal"

ISSUES=()
warn() { ISSUES+=("$*"); echo "  !! $*"; }
ok()   { echo "  ok: $*"; }
section() { echo; echo "=== $* ==="; }
mask() { sed -E 's/\+([0-9]{2})[0-9]{5,9}([0-9]{3})/+\1*****\2/g'; }

echo "================================================================"
echo " signal-check - $(date '+%F %T')"
echo "================================================================"

# --- 1. Kontener ---
section "1. Kontener"
if ! docker inspect "$NAME" >/dev/null 2>&1; then
  warn "brak kontenera $NAME"
  echo; echo "PODSUMOWANIE: kontener nie istnieje"; exit 1
fi
read -r status running restarts oom started image policy < <(docker inspect -f \
  '{{.State.Status}} {{.State.Running}} {{.RestartCount}} {{.State.OOMKilled}} {{.State.StartedAt}} {{.Config.Image}} {{.HostConfig.RestartPolicy.Name}}' "$NAME")
echo "  stan: $status, start (UTC): ${started:0:19}, obraz: $image, restart: $policy"
[ "$running" = "true" ] && ok "dziala" || warn "kontener nie dziala ($status)"
[ "$restarts" = "0" ] && ok "restarty: 0" || warn "restarty: $restarts"
[ "$oom" = "false" ] && ok "bez OOMKilled" || warn "OOMKilled"
[ "$policy" = "unless-stopped" ] || warn "polityka restartu: $policy (oczekiwana unless-stopped)"
img_created=$(docker image inspect -f '{{.Created}}' "$image" 2>/dev/null | cut -c1-10)
echo "  obraz zbudowany: ${img_created:-?} (aktualizacje: ~/Docker/check-updates.sh)"
hstate=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$NAME")
[ -n "$hstate" ] && { [ "$hstate" = "healthy" ] && ok "healthcheck: healthy" || warn "healthcheck: $hstate"; }

# --- 2. API ---
section "2. API i tryb"
PORT=$(docker port "$NAME" 8080/tcp 2>/dev/null | head -1 | sed -E 's/.*:([0-9]+)$/\1/')
PORT="${PORT:-8095}"
API="http://127.0.0.1:$PORT"
hc=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$API/v1/health")
[ "$hc" = "204" ] || [ "$hc" = "200" ] && ok "/v1/health: $hc" || warn "/v1/health: ${hc:-brak odpowiedzi}"
about=$(curl -s --max-time 10 "$API/v1/about")
echo "  /v1/about: $about"
mode=$(echo "$about" | sed -nE 's/.*"mode":"([^"]+)".*/\1/p')
# /v1/about podaje "json-rpc" takze dla json-rpc-native; wariant rozpoznajemy po procesie
procs=$(docker exec "$NAME" ps -eo user,rss,args 2>/dev/null | grep -E 'signal-cli|java' | grep -v grep)
if echo "$procs" | grep -q 'java'; then variant="JVM (json-rpc)"; else variant="native"; fi
case "$mode" in
  json-rpc) ok "tryb: json-rpc, wariant: $variant" ;;
  json-rpc-native) ok "tryb: json-rpc-native" ;;
  "") warn "nie odczytano trybu" ;;
  *) warn "tryb: $mode (oczekiwany json-rpc-native; normal tylko do rejestracji)" ;;
esac
rmode=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$NAME" | sed -n 's/^JSON_RPC_RECEIVE_MODE=//p')
echo "  JSON_RPC_RECEIVE_MODE: ${rmode:-domyslny}"

# --- 3. Konto ---
section "3. Konto"
acc=$(curl -s --max-time 10 "$API/v1/accounts")
echo "  /v1/accounts: $(echo "$acc" | mask)"
n_acc=$(echo "$acc" | grep -oE '\+[0-9]+' | wc -l)
[ "$n_acc" -ge 1 ] && ok "zarejestrowane konta: $n_acc" || warn "brak zarejestrowanego konta"
[ "$n_acc" -gt 1 ] && warn "wiecej niz jedno konto ($n_acc) - oczekiwane tylko konto bota"

# --- 4. Siec i port ---
section "4. Siec i port"
binds=$(docker inspect -f '{{range $p, $c := .NetworkSettings.Ports}}{{range $c}}{{.HostIp}}:{{.HostPort}} {{end}}{{end}}' "$NAME")
echo "  publikacje portow: ${binds:-brak}"
if echo "$binds" | grep -qE '(^| )(0\.0\.0\.0|::|\[::\]|):'; then
  warn "port opublikowany na wszystkich interfejsach - API bez logowania widoczne w LAN"
else
  ok "port tylko na 127.0.0.1"
fi
ss -tln 2>/dev/null | awk -v p=":$PORT" '$4 ~ p"$" {print "  nasluch hosta: " $4}'
echo "  sieci: $(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$NAME")"

# --- 5. Limity i pamiec ---
section "5. Limity i pamiec"
read -r mem cpus < <(docker inspect -f '{{.HostConfig.Memory}} {{.HostConfig.NanoCpus}}' "$NAME")
[ "$mem" != "0" ] && ok "mem_limit: $((mem / 1048576)) MiB" || warn "brak mem_limit"
[ "$cpus" != "0" ] && ok "cpus: $(awk -v c="$cpus" 'BEGIN{printf "%.2f", c/1e9}')" || warn "brak limitu cpus"
if [ -x "$HOME/mem-check.sh" ]; then "$HOME/mem-check.sh" "$NAME" | sed -n '1,2p;/^OK: bez uwag/p;/^Uwagi:/p' | sed 's/^/  /'
elif [ -n "${SUDO_USER:-}" ] && [ -x "$(getent passwd "$SUDO_USER" | cut -d: -f6)/mem-check.sh" ]; then
  "$(getent passwd "$SUDO_USER" | cut -d: -f6)/mem-check.sh" "$NAME" | sed -n '1,2p;/^OK: bez uwag/p;/^Uwagi:/p' | sed 's/^/  /'
else docker stats --no-stream --format '  {{.Name}}: {{.MemUsage}} ({{.MemPerc}}), CPU {{.CPUPerc}}' "$NAME"; fi

# --- 6. Uprawnienia i montowania ---
section "6. Uprawnienia i montowania"
IFS='|' read -r priv user caps < <(docker inspect -f '{{.HostConfig.Privileged}}|{{.Config.User}}|{{.HostConfig.CapAdd}}' "$NAME")
[ "$priv" = "false" ] && ok "privileged: false" || warn "privileged: true"
echo "  user w konfiguracji: ${user:-domyslny obrazu}; cap_add: $caps"
if [ -n "$procs" ]; then
  echo "$procs" | awk '{rss=$2; $2=""; printf "  proces (RSS %d MiB): %s\n", rss/1024, substr($0, 1, 160)}' | head -3
else
  echo "  (nie odczytano procesu signal-cli: brak ps w obrazie?)"
fi
mounts=$(docker inspect -f '{{range .Mounts}}{{.Source}} -> {{.Destination}} ({{if .RW}}rw{{else}}ro{{end}}){{println}}{{end}}' "$NAME" | sed '/^$/d')
echo "$mounts" | sed 's/^/  montowanie: /'
echo "$mounts" | grep -q 'docker.sock' && warn "zamontowany docker.sock" || ok "bez docker.sock"
DATA=$(echo "$mounts" | awk -F' -> ' '/signal-cli/ {print $1}' | head -1)

# --- 7. Katalog danych ---
section "7. Katalog danych (klucze konta)"
if [ -z "$DATA" ] || [ ! -d "$DATA" ]; then
  warn "nie znaleziono katalogu danych ($DATA)"
else
  echo "  $DATA"
  tgt=$(findmnt -n -o TARGET -T "$DATA")
  if [ "$tgt" = "/" ]; then warn "katalog danych na karcie SD (/)"; else ok "na dysku: $tgt"; fi
  read -r owner perm < <(stat -c '%u:%g %a' "$DATA")
  [ "$owner" = "1000:1000" ] && ok "wlasciciel 1000:1000" || warn "wlasciciel $owner (oczekiwany 1000:1000)"
  [ "$perm" = "700" ] && ok "uprawnienia 700" || warn "uprawnienia $perm (oczekiwane 700: klucze konta)"
  du -sh "$DATA" 2>/dev/null | awk '{print "  rozmiar: " $1}'
  # pliki w srodku maja zwykle 644 (umask signal-cli); chroni je katalog 700, do
  # ktorego inni nie wejda. Ostrzezenie tylko, gdy ktorys katalog po drodze jest otwarty.
  opendirs=$(find "$DATA" -type d -perm /o+x 2>/dev/null | head -5)
  if [ -n "$opendirs" ]; then warn "katalogi z kluczami otwarte dla innych:"; echo "$opendirs" | sed 's/^/     /'
  elif [ -r "$DATA" ]; then ok "katalog z kluczami zamkniety dla innych (pliki w srodku chroni 700)"
  else echo "  (zawartosc nieczytelna dla tego uzytkownika - uruchom przez sudo)"; fi
  bad=$(ls -d "${DATA}".bad-* 2>/dev/null)
  [ -n "$bad" ] && echo "  stare katalogi do usuniecia po potwierdzeniu dzialania: $bad (sudo rm -rf ...)"
fi

# --- 8. Compose i .env ---
section "8. Compose i .env"
if [ -d "$SVC_DIR" ]; then
  (cd "$SVC_DIR" && docker compose config -q 2>&1) && ok "docker compose config: OK" || warn "docker compose config: blad"
  if [ -f "$SVC_DIR/.env" ]; then
    grep -E '^SIGNAL_MODE=|^SIGNAL_PORT=' "$SVC_DIR/.env" | sed 's/^/  .env: /'
    if [ -f "$SVC_DIR/.env.example" ]; then
      missing=$(comm -23 <(sed -nE 's/^([A-Z0-9_]+)=.*/\1/p' "$SVC_DIR/.env.example" | sort) <(sed -nE 's/^([A-Z0-9_]+)=.*/\1/p' "$SVC_DIR/.env" | sort))
      [ -z "$missing" ] && ok ".env ma wszystkie klucze z .env.example" || warn "brak w .env: $missing"
    fi
    envmode=$(sed -n 's/^SIGNAL_MODE=//p' "$SVC_DIR/.env")
    [ -n "$mode" ] && [ "${envmode%-native}" != "$mode" ] && [ "$envmode" != "$mode" ] && warn ".env SIGNAL_MODE=$envmode, a dziala $mode (potrzebny apply.sh signal?)"
  else
    warn "brak $SVC_DIR/.env"
  fi
else
  warn "brak katalogu $SVC_DIR"
fi

# --- 9. Logi ---
section "9. Logi z $SINCE"
logs=$(docker logs --since "$SINCE" "$NAME" 2>&1)
echo "  linii: $(echo "$logs" | grep -c .)"
errs=$(echo "$logs" | grep -iE 'error|exception|fail|denied|unauthori|(^|[^0-9.])(403|429|500)([^0-9]|$)' | grep -viE 'level=info|Running as mode|\| 20[0-9] \|')
if [ -n "$errs" ]; then
  warn "bledy w logach: $(echo "$errs" | wc -l) linii (ostatnie ponizej)"
  echo "$errs" | tail -10 | cut -c1-220 | mask | sed -E 's/(signalcaptcha:\/\/)[^ "]+/\1<ukryte>/g' | sed 's/^/     /'
else
  ok "bez bledow"
fi
# ostrzezenie s6 o /run przy starcie jest znane i niegrozne (s6 sam poprawia /run)
echo "$logs" | grep -iE 'warn' | grep -v 'unable to find /run in /proc/mounts' | tail -3 | cut -c1-200 | mask | sed 's/^/  ostrzezenie: /'

# --- 10. Kopie zapasowe ---
section "10. Kopie zapasowe"
BK="$DOCKER_DIR/backup-configs.sh"
if [ -f "$BK" ] && grep -q 'signal_data' "$BK"; then ok "backup-configs.sh obejmuje signal_data"; else warn "backup-configs.sh nie obejmuje signal_data"; fi
DANE4T_DIR="${DANE4T_DIR:-/mnt/Dane4T}"
DEST="${DEST_DIR:-$DANE4T_DIR/data4t/backup/docker_config}"
last=$(ls -1t "$DEST"/*.zip 2>/dev/null | head -1)
if [ -z "$last" ]; then
  echo "  brak archiwow w $DEST (albo brak dostepu - sudo)"
else
  echo "  najnowsze archiwum: $(basename "$last") ($(date -r "$last" '+%F %H:%M'))"
  if command -v unzip >/dev/null && unzip -l "$last" 2>/dev/null | grep -q 'signal_data'; then
    ok "najnowsze archiwum zawiera signal_data"
  else
    warn "najnowsze archiwum nie zawiera signal_data - zrob kopie: sudo ~/Docker/backup-configs.sh"
  fi
fi

# --- 11. Opcjonalny test wysylki ---
if [ -n "${SEND_TO:-}" ]; then
  section "11. Test wysylki (SEND_TO)"
  from=$(echo "$acc" | grep -oE '\+[0-9]+' | head -1)
  res=$(curl -s --max-time 30 -X POST -H 'Content-Type: application/json' \
    -d "{\"message\":\"signal-check $(date '+%F %T')\",\"number\":\"$from\",\"recipients\":[\"$SEND_TO\"]}" "$API/v2/send")
  echo "  odpowiedz: $(echo "$res" | mask | cut -c1-200)"
  echo "$res" | grep -q '"timestamp"' && ok "wyslano - sprawdz telefon" || warn "wysylka nieudana"
fi

echo
echo "================================================================"
echo " PODSUMOWANIE"
echo "================================================================"
if [ ${#ISSUES[@]} -eq 0 ]; then
  echo " OK: bez uwag"
else
  printf ' - %s\n' "${ISSUES[@]}"
fi
