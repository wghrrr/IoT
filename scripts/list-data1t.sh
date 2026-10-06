#!/bin/bash
# list-data1t.sh - przeglad zawartosci dysku danych (domyslnie /mnt/Data1T):
# rozmiary, struktura 2 poziomow w glab, wlasciciele/uprawnienia.
#
# Uzycie:
#   sudo ./list-data1t.sh                # domyslnie /mnt/Data1T
#   sudo ./list-data1t.sh /mnt/Dane4T     # albo dowolny inny dysk
#
# sudo potrzebne, zeby du/ls widzialy katalogi kontenerow (np. bazy danych, root:root).
# Wynik moze zawierac nazwy plikow i katalogow z danymi - nie publikuj go bez przejrzenia.

MOUNT="${1:-/mnt/Data1T}"

echo "================================================================"
echo " Przeglad: $MOUNT - $(date '+%Y-%m-%d %H:%M:%S')"
echo "================================================================"

echo
echo "--- df -h ---"
df -h "$MOUNT"

echo
echo "--- Rozmiary katalogow najwyzszego poziomu (posortowane malejaco) ---"
du -sh "$MOUNT"/* 2>/dev/null | sort -rh

echo
echo "--- Wlasciciele / uprawnienia najwyzszego poziomu ---"
ls -la "$MOUNT"

echo
echo "--- Struktura 2 poziomow w glab ---"
find "$MOUNT" -maxdepth 2 -mindepth 1 2>/dev/null | sort

echo
echo "================================================================"
echo " Koniec"
echo "================================================================"
