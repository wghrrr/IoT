#!/bin/bash
# rpi-daily.sh - codzienny przeglad stanu RPi: USB, dyski, SMART, kontenery,
# zasoby, karta SD i logi Home Assistant. Tylko czyta, nic nie zmienia.
#
# Uzycie:
#   sudo ./rpi-daily.sh                 # logi HA z ostatnich 24 h
#   sudo SINCE=72h ./rpi-daily.sh       # dluzszy zakres logow HA
#   sudo SMART=0 ./rpi-daily.sh         # bez SMART (szybciej, nie budzi dyskow)
#
# Na koncu jest PODSUMOWANIE z lista rzeczy do sprawdzenia. Wynik zawiera
# nazwy urzadzen i sciezki - do rozmowy tak, do repo nie. Sekrety w logach HA
# sa maskowane (klucze password/token/..., JWT, dlugie ciagi base64).

SINCE="${SINCE:-24h}"
SMART="${SMART:-1}"
DISK_WARN_PCT="${DISK_WARN_PCT:-90}"
TEMP_WARN_C="${TEMP_WARN_C:-75}"

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
  M='s/((password|passwd|secret|token|credentials|bearer|authorization|api_?key)[^:= ]*["]?[:= ]+["]?)[^ ,}"]+/\1***/Ig; s/eyJ[A-Za-z0-9_.-]+/***JWT***/g; s/[A-Za-z0-9+\/_=-]{40,}/***B64***/g'
  HA_LOG=$(docker logs --since "$SINCE" homeassistant 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g' | sed -E "$M")
  echo "-- zrodla ostrzezen i bledow (liczba)"
  echo "$HA_LOG" | grep -oE '(WARNING|ERROR|CRITICAL) \([^)]*\) \[[^]]+\]' | sed -E 's/ \([^)]*\)//' | sort | uniq -c | sort -rn | head -25
  echo "-- ZHA / Bluetooth"
  echo "$HA_LOG" | grep -iE 'zha|bellows|zigpy|ezsp|bluetooth|bleak|habluetooth|ble_monitor|Watchdog|tx timeout' | grep -E 'WARNING|ERROR|CRITICAL|zha_diag' | cut -c1-220 | tail -20
  echo "-- zha_diag (znikajace urzadzenia)"
  echo "$HA_LOG" | grep 'zha_diag' | cut -c1-200 | tail -15
  echo "-- pozostale ERROR"
  echo "$HA_LOG" | grep -E ' (ERROR|CRITICAL) ' | grep -viE 'bluetooth|bleak|habluetooth|ble_monitor|zha|bellows|zigpy' | cut -c1-220 | tail -15
  n=$(echo "$HA_LOG" | grep -cE ' (ERROR|CRITICAL) ')
  [ "$n" -lt 20 ] || warn "HA: $n linii ERROR/CRITICAL w $SINCE"
else
  warn "kontener homeassistant nie dziala"
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
