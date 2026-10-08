#!/bin/bash
# backup-sd.sh - skompresowany obraz calej karty SD (system) na dysk danych.
#
# Uzycie:
#   sudo ./backup-sd.sh
#   sudo DEST_DIR=/mnt/Data1T/backup/rpi_sd ./backup-sd.sh
#   sudo GPG_RECIPIENT=<adres_klucza> ./backup-sd.sh    # dodatkowo szyfruje (gpg) i usuwa jawny obraz
#
# Obraz robiony z dzialajacego systemu jest jak po naglym odcieciu pradu:
# po przywroceniu system zrobi fsck i zwykle startuje. Dane uslug sa na
# dyskach, wiec na karcie zmienia sie niewiele; przed kopia jest "sync".
#
# Przywracanie: Raspberry Pi Imager przyjmuje .img.gz bezposrednio, albo:
#   gunzip -c plik.img.gz | sudo dd of=/dev/sdX bs=4M status=progress
#
# Duzo zapisow przez USB - nie uruchamiaj, gdy kontroler USB/dyski sa
# niestabilne (np. tuz po awarii "HC died").
set -euo pipefail

SRC="${SRC:-/dev/mmcblk0}"
DEST_DIR="${DEST_DIR:-/mnt/Dane4T/data4t/backup/rpi_sd}"
MIN_FREE_GB="${MIN_FREE_GB:-35}"

[ "$(id -u)" -eq 0 ] || { echo "Uruchom przez sudo" >&2; exit 1; }
[ -b "$SRC" ] || { echo "Brak urzadzenia $SRC" >&2; exit 1; }

# dysk docelowy musi byc zamontowany - inaczej obraz trafilby na sama karte SD
p="$DEST_DIR"
while [ ! -e "$p" ]; do p=$(dirname "$p"); done   # DEST_DIR moze jeszcze nie istniec
MNT=$(findmnt -no TARGET --target "$p" 2>/dev/null || true)
case "$MNT" in
  /mnt/?*) ;;
  *) echo "Katalog $DEST_DIR nie lezy na zamontowanym dysku (/mnt/...) - przerywam" >&2; exit 1 ;;
esac
free_gb=$(df --output=avail -BG "$MNT" | tail -1 | tr -dc 0-9)
[ "$free_gb" -gt "$MIN_FREE_GB" ] || { echo "Za malo miejsca na $MNT: ${free_gb} GB (min. ${MIN_FREE_GB})" >&2; exit 1; }

mkdir -p "$DEST_DIR"
OUT="$DEST_DIR/rpi_sd_backup_$(date +%Y%m%d_%H%M%S).img.gz"

echo "Kopia $SRC -> $OUT (niski priorytet I/O i CPU)"
sync
ionice -c3 nice -n19 dd if="$SRC" bs=4M status=progress | ionice -c3 nice -n19 gzip -1 > "$OUT"

echo "Sprawdzanie archiwum..."
gzip -t "$OUT" && echo "OK: archiwum spojne"
ls -lh "$OUT"

if [ -n "${GPG_RECIPIENT:-}" ]; then
  gpg --batch --yes --output "$OUT.gpg" --encrypt --recipient "$GPG_RECIPIENT" "$OUT"
  rm -f "$OUT"
  ls -lh "$OUT.gpg"
fi
