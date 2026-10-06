#!/bin/bash
# Inwentaryzacja stanu hosta - co trzeba odtworzyc po reinstalacji OS,
# poza samym ~/Docker (ktory zabezpiecza backup-configs.sh).
#
# Wylacznie do odczytu - nic nie zmienia, nic nie zapisuje. Uruchom z
# sudo, zeby zobaczyc tez rzeczy wymagajace roota (blkid, dhcpcd.conf,
# crontab roota).
#
# UWAGA: wynik zawiera dane wrazliwe (UUID dyskow, adresy IP, crontaby,
# konfiguracje sieci) - trzymaj go lokalnie, nie publikuj.
#
# Uzycie: sudo ./inventory.sh [> inventory-$(date +%F).txt]
set -uo pipefail

# pod sudo $HOME to /root, nie /home/pi - bez tego sekcja ~/Docker nic nie znajdzie
if [ -n "${SUDO_USER:-}" ]; then
  REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
  REAL_HOME="$HOME"
fi

hr() { printf -- '=%.0s' $(seq 1 70); echo; }
sec() { echo; hr; echo " $1"; hr; }

sec "SYSTEM"
echo "Hostname: $(hostname)"
cat /proc/cpuinfo | grep -m1 Model
cat /etc/os-release 2>/dev/null | grep -E '^(PRETTY_NAME|VERSION)='
uname -a
uptime

sec "DYSKI - blkid (UUID do fstab)"
sudo blkid 2>/dev/null || echo "(brak sudo - uruchom z sudo zeby zobaczyc)"

sec "DYSKI - lsblk"
lsblk -o NAME,SIZE,TRAN,FSTYPE,MOUNTPOINT,MODEL

sec "DYSKI - /etc/fstab (docelowy stan do odtworzenia)"
cat /etc/fstab

sec "DYSKI - zywe mounty (porownaj z fstab - lapie niespodzianki typu noexec)"
mount | grep -E '^/dev/'

sec "DYSKI - df -h"
df -h

sec "SIEC - adres/interfejs"
ip -4 addr show | grep -E 'inet |^[0-9]+:'
echo "--- domyslna brama ---"
ip route | grep default
echo "--- DNS (resolv.conf) ---"
cat /etc/resolv.conf 2>/dev/null | grep -v '^#'

sec "SIEC - ip_forward (wymagane dla VPN/routingu do LAN)"
echo "Aktualna wartosc runtime: $(sysctl -n net.ipv4.ip_forward 2>/dev/null)"
echo "--- czy jest TRWALE zapisane (jesli pusto - zniknie po reboocie!) ---"
grep -rH 'ip_forward' /etc/sysctl.conf /etc/sysctl.d/ 2>/dev/null || echo "BRAK - nigdzie nie zapisane trwale!"

sec "SIEC - staly IP na samym Pi (jesli skonfigurowany poza routerem)"
grep -A5 'interface eth0' /etc/dhcpcd.conf 2>/dev/null || echo "(brak dhcpcd.conf albo brak wpisu dla eth0 - IP idzie czysto z DHCP/routera)"

sec "DDNS - czy cos aktualizuje domene na tym hoscie"
systemctl status ddclient --no-pager 2>/dev/null | head -5 || echo "ddclient: brak takiej uslugi"
echo "--- crontab pod katem ddns ---"
{ crontab -l 2>/dev/null; sudo crontab -l 2>/dev/null; } | grep -i -E 'ddns|duckdns|dyndns|no-ip' || echo "(nic nie znaleziono w crontabach)"

sec "CRON - crontab usera pi"
crontab -l 2>/dev/null || echo "(pusty/brak)"

sec "CRON - crontab roota"
sudo crontab -l 2>/dev/null || echo "(pusty/brak, albo brak sudo)"

sec "SYSTEMD - wlasne/niestandardowe jednostki w /etc/systemd/system"
find /etc/systemd/system -maxdepth 1 -type f \( -name '*.service' -o -name '*.timer' \) -exec basename {} \; 2>/dev/null
echo "--- ich status ---"
for u in $(find /etc/systemd/system -maxdepth 1 -type f \( -name '*.service' -o -name '*.timer' \) -printf '%f\n' 2>/dev/null); do
  printf "%-40s %s\n" "$u" "$(systemctl is-enabled "$u" 2>/dev/null) / $(systemctl is-active "$u" 2>/dev/null)"
done

sec "DOCKER - wersja i data-root"
docker --version
docker compose version 2>/dev/null
echo "--- Root Dir ---"
docker info 2>/dev/null | grep "Docker Root Dir"
echo "--- daemon.json (jesli jest) ---"
cat /etc/docker/daemon.json 2>/dev/null || echo "(brak /etc/docker/daemon.json)"

sec "DOCKER - kontenery"
docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'

sec "DOCKER - NAZWANE wolumeny (fizycznie w data-root, wymagaja eksportu/importu, nie tylko bind-mount!)"
docker volume ls
echo "--- rozmiary ---"
for v in $(docker volume ls -q); do
  size=$(docker run --rm -v "$v":/vol:ro alpine du -sh /vol 2>/dev/null | cut -f1)
  echo "$v: ${size:-?}"
done

sec "DOCKER - sieci"
docker network ls

sec "~/Docker - foldery uslug i czy maja .env"
for d in "$REAL_HOME"/Docker/*/; do
  name=$(basename "$d")
  env_status="brak .env"
  [ -f "${d}.env" ] && env_status="MA .env"
  compose_file=""
  [ -f "${d}docker-compose.yml" ] && compose_file="${d}docker-compose.yml"
  [ -f "${d}docker-compose.yaml" ] && compose_file="${d}docker-compose.yaml"
  named_vols="-"
  if [ -n "$compose_file" ]; then
    # sekcja "volumes:" na najwyzszym poziomie (bez wciecia) = nazwane wolumeny
    if grep -qE '^volumes:' "$compose_file"; then
      named_vols=$(awk '/^volumes:/{f=1;next} f&&/^[a-zA-Z]/{exit} f&&/^  [a-zA-Z0-9_-]+:/{print $1}' "$compose_file" | tr -d ':' | tr '\n' ',' )
    fi
  fi
  printf "%-30s %-12s nazwane wolumeny: %s\n" "$name" "$env_status" "${named_vols:--}"
done

sec "APT - recznie zainstalowane pakiety (do doinstalowania po reinstalacji)"
apt-mark showmanual 2>/dev/null | grep -v -E '^(raspberrypi-kernel|firmware-|libraspberrypi|rpi-)' | sort

sec "SSH - klucze autoryzowane dla usera pi (tylko liczba, nie tresc)"
if [ -f "$REAL_HOME/.ssh/authorized_keys" ]; then
  echo "authorized_keys: $(wc -l < "$REAL_HOME/.ssh/authorized_keys") wpis(y)"
else
  echo "brak ~/.ssh/authorized_keys"
fi

echo
hr
echo " Koniec inwentaryzacji"
hr
