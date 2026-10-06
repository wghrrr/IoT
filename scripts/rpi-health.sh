#!/bin/bash
# rpi-health.sh - szybki raport stanu systemu (load, RAM, swap, dyski, kontenery)
#
# Uzycie:
#   ./rpi-health.sh          # podstawowy raport
#   sudo ./rpi-health.sh     # + dodatkowa sekcja iotop (wymaga roota)
#
# Jedna komenda zamiast kilku osobnych - wynik przydaje sie przy diagnozie problemow.

echo "================================================================"
echo " RPi Health Report - $(date '+%Y-%m-%d %H:%M:%S')"
echo "================================================================"

echo
echo "--- UPTIME / LOAD ---"
uptime

echo
echo "--- PROCESY: r=gotowe do biegu, b=zablokowane na I/O (3 probki co 1s) ---"
vmstat 1 3

echo
echo "--- PAMIEC (free -h) ---"
free -h

echo
echo "--- DYSKI (df -h) ---"
df -h / /mnt/Dane4T /mnt/Filmy4T /mnt/Data1T 2>/dev/null

echo
echo "--- TOP 12 procesow wg RAM ---"
ps aux --sort=-%mem | head -13

echo
echo "--- TOP 8 procesow wg CPU ---"
ps aux --sort=-%cpu | head -9

echo
echo "--- DOCKER: status kontenerow ---"
if command -v docker >/dev/null 2>&1; then
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"
else
  echo "docker niedostepny w PATH"
fi

echo
echo "--- DOCKER: zasoby per-kontener (CPU/MEM/BLOCK IO) ---"
if command -v docker >/dev/null 2>&1; then
  docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}\t{{.BlockIO}}"
fi

if [ "$(id -u)" -eq 0 ]; then
  echo
  echo "--- I/O: krotki sample iotop (3x1s, tylko z sudo) ---"
  iotop -b -o -d 1 -n 3 2>/dev/null
else
  echo
  echo "(pomijam sekcje iotop - uruchom z 'sudo' zeby ja zobaczyc)"
fi

echo
echo "================================================================"
echo " Koniec raportu"
echo "================================================================"
