#!/bin/bash
# rpi-daily.sh - codzienny przeglad stanu RPi: USB, dyski, SMART, kontenery,
# zasoby, karta SD, logi Home Assistant i baterie Zigbee/BLE. Tylko czyta.
#
# Uzycie:
#   sudo ./rpi-daily.sh                 # logi HA z ostatnich 24 h
#   sudo SINCE=72h ./rpi-daily.sh       # dluzszy zakres logow HA
#   sudo SMART=0 ./rpi-daily.sh         # bez SMART (szybciej, nie budzi dyskow)
#   sudo BAT_WARN_PCT=30 ./rpi-daily.sh # prog niskiej baterii (domyslnie 20%)
#
# Baterie czytane z API HA tokenem Prometheusa (hass_token); inny plik:
# HA_TOKEN_FILE=/sciezka/hass_token. BAT_STALE_H = alarm, gdy urzadzenie z bateria
# (zadna jego encja) nie raportowalo dluzej niz tyle godzin (domyslnie 48).
#
# Na koncu jest PODSUMOWANIE z lista rzeczy do sprawdzenia. Wynik zawiera
# nazwy urzadzen i sciezki - do rozmowy tak, do repo nie. Sekrety w logach HA
# sa maskowane (klucze password/token/..., JWT, dlugie ciagi base64).

SINCE="${SINCE:-24h}"
SMART="${SMART:-1}"
DISK_WARN_PCT="${DISK_WARN_PCT:-90}"
TEMP_WARN_C="${TEMP_WARN_C:-75}"
BAT_WARN_PCT="${BAT_WARN_PCT:-20}"
BAT_STALE_H="${BAT_STALE_H:-48}"

[ "$(id -u)" -eq 0 ] || { echo "Uruchom przez sudo" >&2; exit 1; }

ISSUES=()
warn() { ISSUES+=("$*"); echo "  !! $*"; }
section() { echo; echo "=== $* ==="; }
have() { command -v "$1" >/dev/null 2>&1; }

echo "================================================================"
echo " RPi daily - $(date '+%Y-%m-%d %H:%M:%S'), logi HA: $SINCE"
echo "================================================================"

section "1. Uptime i parametry startu"
uptime
echo "start systemu: $(uptime -s)"
q=$(grep -o 'usb-storage.quirks=[^ ]*' /boot/firmware/cmdline.txt 2>/dev/null)
echo "quirks: ${q:-brak}"
[ -n "$q" ] || warn "brak usb-storage.quirks w cmdline.txt (UAS wlaczony?)"

section "2. Zasilanie i temperatura"
if have vcgencmd; then
  thr=$(vcgencmd get_throttled | cut -d= -f2)
  temp=$(vcgencmd measure_temp | grep -oE '[0-9]+\.[0-9]+')
  echo "throttled=$thr  temp=${temp}C"
  [ "$thr" = "0x0" ] || warn "throttled=$thr (bit 0/16 = podnapiecie, 2/18 = throttling)"
  [ "${temp%.*}" -lt "$TEMP_WARN_C" ] || warn "temperatura ${temp}C"
fi

section "3. USB: kontroler i topologia"
x=$(dmesg -T | grep -iE 'HC died|Host System Error|host controller not responding')
if [ -n "$x" ]; then echo "$x" | tail -10; warn "awaria kontrolera USB (xHCI) od startu"; else echo "xHCI: OK"; fi
lsusb -t
lsusb -t | grep -q 'Driver=uas' && warn "dysk pracuje na uas (powinien usb-storage)"

section "4. Mounty, Docker, radia"
for m in /mnt/Data1T /mnt/Dane4T /mnt/Filmy4T; do
  findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS "$m" || warn "nie zamontowany: $m"
done
for s in docker bluetooth; do
  st=$(systemctl is-active "$s"); echo "$s: $st"; [ "$st" = active ] || warn "usluga $s: $st"
done
rfkill list | grep -A2 hci1
rfkill list | grep -A2 hci1 | grep -q 'Soft blocked: yes' && warn "hci1 zablokowany przez rfkill (sudo rfkill unblock <nr>)"
ls /dev/serial/by-id/ 2>/dev/null || warn "brak /dev/serial/by-id (dongle Zigbee?)"
have bluetoothctl && bluetoothctl list

section "5. Kernel: bledy i ostrzezenia (od startu)"
k=$(dmesg -T --level=emerg,alert,crit,err,warn | grep -vE 'staging directory|dummy regulator|Transparent Hugepage|not valid maps|Optimal transfer size|cgroup_memory|orphan cleanup on readonly')
if [ -n "$k" ]; then echo "$k" | tail -30; echo "(lacznie linii: $(echo "$k" | wc -l))"; else echo "brak"; fi
e=$(dmesg -T | grep -iE 'usb .*disconnect|I/O error|EXT4-fs (error|warning)|over-current|reset (high|super)-speed|out of memory|killed process|under-voltage')
if [ -n "$e" ]; then echo "-- USB/dyski/OOM:"; echo "$e" | tail -20; warn "kernel: $(echo "$e" | wc -l) linii USB/IO/OOM (sekcja 5)"; fi

section "6. Miejsce na dyskach"
df -h / /mnt/Dane4T /mnt/Filmy4T /mnt/Data1T 2>/dev/null
while read -r pct mnt; do
  p=${pct%\%}; [ "$p" -lt "$DISK_WARN_PCT" ] || warn "dysk $mnt zajety w $pct"
done < <(df --output=pcent,target / /mnt/Dane4T /mnt/Filmy4T /mnt/Data1T 2>/dev/null | tail -n +2)

section "7. SMART"
if [ "$SMART" != 1 ]; then echo "pominiety (SMART=0)"
elif ! have smartctl; then echo "brak smartctl (sudo apt install smartmontools)"
else
  for d in $(lsblk -dno NAME,TRAN | awk '$2=="usb"{print $1}'); do
    mnt=$(lsblk -no MOUNTPOINT "/dev/$d" | grep -m1 .)
    echo "== /dev/$d ${mnt:-?}"
    out=$(smartctl -a -d sat "/dev/$d" 2>&1)
    echo "$out" | grep -E 'Device Model|overall|Power_On_Hours|Reallocated_Sector|Current_Pending|Offline_Uncorrectable|UDMA_CRC|Temperature_Celsius'
    echo "$out" | grep -q 'overall-health.*PASSED' || warn "SMART /dev/$d (${mnt:-?}): brak PASSED"
    for a in Reallocated_Sector_Ct Current_Pending_Sector Offline_Uncorrectable; do
      v=$(echo "$out" | awk -v a="$a" '$2==a{print $10}')
      [ -z "$v" ] || [ "$v" = 0 ] || warn "SMART /dev/$d (${mnt:-?}): $a=$v"
    done
  done
fi

section "8. Kontenery"
if have docker; then
  docker ps -a --format 'table {{.Names}}\t{{.Status}}'
  for id in $(docker ps -aq); do
    read -r name state oom rc pol code err < <(docker inspect -f '{{.Name}} {{.State.Status}} {{.State.OOMKilled}} {{.RestartCount}} {{.HostConfig.RestartPolicy.Name}} {{.State.ExitCode}} {{.State.Error}}' "$id")
    name=${name#/}
    [ "$oom" = false ] || warn "kontener $name: OOMKilled"
    [ "$rc" = 0 ] || warn "kontener $name: restartow $rc"
    [ "$state" = running ] && continue
    # unless-stopped w stanie exited = zatrzymany recznie (status uslug: README);
    # alarm tylko, gdy Docker nie zdolal go uruchomic albo polityka wymaga dzialania
    if [ -n "$err" ]; then warn "kontener $name: $state, blad startu: $err"
    elif [ "$pol" = always ]; then warn "kontener $name: $state (restart: always)"
    elif [ "$pol" = on-failure ] && [ "$code" != 0 ]; then warn "kontener $name: $state, kod $code (restart: on-failure)"
    fi
  done
  docker ps --format '{{.Names}} {{.Status}}' | grep -q unhealthy && warn "kontener unhealthy (sekcja 8)"
  echo
  docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.BlockIO}}'
  echo
  docker system df
else
  warn "docker niedostepny"
fi

section "9. Pamiec i obciazenie"
free -h
swapon --show
read -r st su < <(free -m | awk '/^Swap/{print $2, $3}')
[ "${st:-0}" -eq 0 ] || [ $((su * 100 / st)) -lt 50 ] || warn "swap zajety w $((su * 100 / st))%"
vmstat 2 3
# druga probka iostat = biezace 5 s (pierwsza to srednia od startu)
have iostat && iostat -dx 5 2 | awk '/^Device/{h=$0} /^sd/{l[$1]=$0} END{print h; for (d in l) print l[d]}'

section "10. Karta SD"
awk '{printf "zapisano na karte od startu: %.1f GB\n", $7*512/1e9}' /sys/block/mmcblk0/stat
uptime -p
journalctl --disk-usage

section "11. Home Assistant: logi z $SINCE (maskowane)"
if docker ps --format '{{.Names}}' | grep -qx homeassistant; then
  M='s/((password|passwd|secret|token|credentials|bearer|authorization|api_?key)[^:= ]*["]?[:= ]+["]?)[^ ,}"]+/\1***/Ig; s/eyJ[A-Za-z0-9_.-]+/***JWT***/g'
  # B64: ciag >= 40 znakow z mala litera lub cyfra (stale typu CONCENTRATION_... zostaja)
  HA_LOG=$(docker logs --since "$SINCE" homeassistant 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g' | sed -E "$M" \
    | perl -pe 's/(?=[A-Za-z0-9+\/_=-]*[a-z0-9])[A-Za-z0-9+\/_=-]{40,}/***B64***/g')
  echo "-- zrodla ostrzezen i bledow (liczba)"
  echo "$HA_LOG" | grep -oE '(WARNING|ERROR|CRITICAL) \([^)]*\) \[[^]]+\]' | sed -E 's/ \([^)]*\)//' | sort | uniq -c | sort -rn | head -25
  echo "-- ZHA / Bluetooth"
  echo "$HA_LOG" | grep -iE 'zha|bellows|zigpy|ezsp|bluetooth|bleak|habluetooth|ble_monitor|Watchdog|tx timeout' | grep -E ' (WARNING|ERROR|CRITICAL) \(|zha_diag' | cut -c1-220 | tail -20
  echo "-- zha_diag (znikajace urzadzenia)"
  echo "$HA_LOG" | grep 'zha_diag' | cut -c1-200 | tail -15
  echo "-- pozostale ERROR"
  echo "$HA_LOG" | grep -E ' (ERROR|CRITICAL) ' | grep -viE 'bluetooth|bleak|habluetooth|ble_monitor|zha|bellows|zigpy' | cut -c1-220 | tail -15
  n=$(echo "$HA_LOG" | grep -cE ' (ERROR|CRITICAL) ')
  [ "$n" -lt 20 ] || warn "HA: $n linii ERROR/CRITICAL w $SINCE"
  z=$(echo "$HA_LOG" | grep 'zha_diag' | grep -v 'wrocilo' | sed -E 's/.*\[zha_diag\] //' | cut -c1-80 | sort | uniq -c | awk '{$1=$1" x"; print}' | paste -sd ';' -)
  [ -z "$z" ] || warn "HA zha_diag: $z"
else
  warn "kontener homeassistant nie dziala"
fi

section "12. Home Assistant: baterie Zigbee i BLE"
# Stany z API HA (localhost:8123, HA w network_mode: host), token ten sam co dla
# Prometheusa (hass_token w jego katalogu config). Platforma encji z rejestru HA.
HA_CONF=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/config"}}{{.Source}}{{end}}{{end}}' homeassistant 2>/dev/null)
PROM_CONF=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/prometheus"}}{{.Source}}{{end}}{{end}}' monitoring-prometheus 2>/dev/null)
HA_TOKEN_FILE="${HA_TOKEN_FILE:-${PROM_CONF:+$PROM_CONF/hass_token}}"
if [ ! -f "$HA_CONF/.storage/core.entity_registry" ]; then echo "brak rejestru encji HA (kontener homeassistant?)"
elif [ ! -r "$HA_TOKEN_FILE" ]; then warn "baterie: brak tokena HA (HA_TOKEN_FILE=/sciezka/hass_token)"
elif ! have python3; then echo "brak python3"
else
  # naglowek przez stdin, zeby token nie trafil do listy procesow
  STATES=$(printf 'Authorization: Bearer %s\n' "$(tr -d '[:space:]' < "$HA_TOKEN_FILE")" \
    | curl -sf --max-time 15 -H @- http://localhost:8123/api/states)
  if [ -z "$STATES" ]; then warn "baterie: API HA nie odpowiada (localhost:8123 lub zly token)"
  else
    while IFS= read -r line; do
      case "$line" in WARN:*) warn "${line#WARN: }" ;; *) echo "$line" ;; esac
    # stany jako plik (argv[2]) - stdin zajmuje sam skrypt z heredoca
    done < <(BAT_WARN_PCT="$BAT_WARN_PCT" BAT_STALE_H="$BAT_STALE_H" \
      python3 - "$HA_CONF/.storage/core.entity_registry" <(echo "$STATES") <<'PY'
import json, os, sys
from datetime import datetime, timezone
warn_pct, stale_h = int(os.environ["BAT_WARN_PCT"]), int(os.environ["BAT_STALE_H"])
BLE = {"bthome", "xiaomi_ble", "ble_monitor", "switchbot", "govee_ble", "inkbird", "sensorpush",
       "qingping", "oralb", "thermobeacon", "thermopro", "yalexs_ble", "ibeacon", "bluemaestro",
       "moat", "mopeka", "sensirion_ble", "tilt_ble", "victron_ble", "kegtron", "airthings_ble"}
reg = {e["entity_id"]: e for e in json.load(open(sys.argv[1]))["data"]["entities"]}
now = datetime.now(timezone.utc)
def hours(s):
    ts = s.get("last_reported") or s.get("last_updated")
    return (now - datetime.fromisoformat(ts)).total_seconds() / 3600 if ts else 0
states = json.load(open(sys.argv[2]))
# aktywnosc urzadzenia = najswiezszy raport dowolnej jego encji; wiele czujnikow
# Zigbee wysyla baterie rzadko albo tylko przy zmianie, a samo urzadzenie zyje
dev_age = {}
for s in states:
    d = reg.get(s["entity_id"], {}).get("device_id")
    if d and s["state"] not in ("unavailable", "unknown"):
        dev_age[d] = min(dev_age.get(d, 1e9), hours(s))
rows, warns = [], []
for s in states:
    eid, a = s["entity_id"], s.get("attributes", {})
    if a.get("device_class") != "battery" or eid.split(".")[0] not in ("sensor", "binary_sensor"):
        continue
    plat = reg.get(eid, {}).get("platform", "?")
    if plat == "zha": kind = "Zigbee"
    elif plat in BLE: kind = "BLE"
    else: continue
    name = a.get("friendly_name") or eid
    age = hours(s)
    dage = dev_age.get(reg[eid].get("device_id"), age)
    st = s["state"]
    if st in ("unavailable", "unknown"):
        val, sort = st, -1
        # unknown przy zywym urzadzeniu = bateria jeszcze nie raportowana od startu HA
        if st == "unavailable" or dage > stale_h:
            warns.append(f"bateria {kind} {name}: {st}")
    elif eid.startswith("binary_sensor."):
        val, sort = ("NISKA" if st == "on" else "ok"), (0 if st == "on" else 100)
        if st == "on": warns.append(f"bateria {kind} {name}: niska")
    else:
        try: pct = float(st)
        except ValueError: continue
        val, sort = f"{pct:.0f}%", pct
        if pct < warn_pct: warns.append(f"bateria {kind} {name}: {pct:.0f}%")
    if st != "unavailable" and dage > stale_h:
        warns.append(f"{kind} {name}: urzadzenie milczy od {dage:.0f} h")
    rows.append((sort, kind, val, f"{age:.0f}h", f"{dage:.0f}h", name, plat))
if not rows:
    print("brak encji baterii Zigbee/BLE")
else:
    print(f"  {'typ':<6} {'bateria':>11}  {'raport bat.':>11}  {'urzadz.':>7}  nazwa")
for r in sorted(rows):
    print(f"  {r[1]:<6} {r[2]:>11}  {r[3]:>11}  {r[4]:>7}  {r[5]}  [{r[6]}]")
for w in warns:
    print("WARN: " + w)
PY
)
  fi
fi

echo
echo "================================================================"
echo " PODSUMOWANIE"
echo "================================================================"
if [ ${#ISSUES[@]} -eq 0 ]; then
  echo "OK - nic nie wymaga uwagi"
else
  printf ' - %s\n' "${ISSUES[@]}"
fi
