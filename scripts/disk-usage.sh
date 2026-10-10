#!/bin/bash
# disk-usage.sh - co naprawde zajmuje miejsce na dyskach danych. Tylko czyta,
# nic nie usuwa. Jedno przejscie find na dysk (niski priorytet CPU i I/O),
# z niego: katalogi do glebokosci DEPTH, typy plikow, rok modyfikacji,
# najwieksze pliki, smieci (AppleDouble, kosze, niedokonczone pobrania),
# kandydaci na duplikaty. Do tego: rezerwa root (ext4), usuniete-ale-otwarte
# pliki, Docker (data-root, obrazy, logi kontenerow).
#
# Uzycie:
#   sudo ./disk-usage.sh > ~/disk-usage-$(date +%F).txt      # trzy dyski
#   sudo ./disk-usage.sh /mnt/Dane4T                         # jeden dysk
#   sudo DEPTH=4 TOP=40 ./disk-usage.sh /mnt/Data1T          # glebiej, wiecej pozycji
#   sudo DUPES=1 ./disk-usage.sh /mnt/Filmy4T                # duplikaty po skrocie (wolniej)
#
# Zmienne: DEPTH (3) glebokosc katalogow, TOP (25) pozycji na liste,
# BIG_MB (2048) prog "duzego pliku", DUP_MB (100) minimalny rozmiar
# kandydata na duplikat, DUPES (0) 1 = skrot md5 z pierwszych i ostatnich
# 4 MB dla plikow o tym samym rozmiarze (czyta dysk, kilka-kilkanascie min).
#
# Na 4 TB przez USB jedno przejscie trwa od kilku do kilkudziesieciu minut,
# zalezne od liczby plikow (Immich: duzo malych). Wynik zawiera nazwy plikow
# i katalogow - do rozmowy tak, do repo nie.

DEPTH="${DEPTH:-3}"
TOP="${TOP:-25}"
BIG_MB="${BIG_MB:-2048}"
DUP_MB="${DUP_MB:-100}"
DUPES="${DUPES:-0}"

[ "$(id -u)" -eq 0 ] || { echo "Uruchom przez sudo" >&2; exit 1; }

if [ $# -gt 0 ]; then MOUNTS=("$@"); else MOUNTS=(/mnt/Data1T /mnt/Dane4T /mnt/Filmy4T); fi

T=$(mktemp -d) || exit 1
trap 'rm -rf "$T"' EXIT
LOW="nice -n 19 ionice -c3"

section() { echo; echo "=== $* ==="; }
have() { command -v "$1" >/dev/null 2>&1; }
# kB -> czytelnie (awk, bez numfmt)
HUM='function hum(k){ if(k>=1073741824) return sprintf("%.2f TB",k/1073741824); if(k>=1048576) return sprintf("%.1f GB",k/1048576); if(k>=1024) return sprintf("%.0f MB",k/1024); return sprintf("%d kB",k) }'

# wejscie: rozmiar_B \t klucz \t sciezka; wyjscie per grupa (>=2 pliki):
# odzysk_kB \t kopii \t klucz \t sciezki rozdzielone \037
group_dups() {
  sort -t$'\t' -k1,1n -k2,2 | awk -F'\t' '
    function flush() { if (c>1) printf "%.0f\t%d\t%s\t%s\n", s*(c-1)/1024, c, n, g }
    { key=$1 "\t" $2; if (key==pk) { g=g "\037" $3; c++ } else { flush(); pk=key; s=$1; n=$2; g=$3; c=1 } }
    END{ flush() }'
}
print_dups() {
  [ -s "$1" ] || { echo "brak"; return; }
  sort -t$'\t' -k1,1nr "$1" | head -n "$TOP" | awk -F'\t' "$HUM"'{
    printf "%s do odzyskania, %d kopii, %s\n", hum($1), $2, $3; n=split($4, z, "\037"); for (i=1;i<=n;i++) print "    " z[i] }'
}
sum_kb() { awk -F'\t' '{k+=$1} END{printf "%.0f", k}' "$1"; }

SUMMARY=()

echo "================================================================"
echo " Zajetosc dyskow - $(date '+%Y-%m-%d %H:%M:%S')"
echo " DEPTH=$DEPTH TOP=$TOP BIG_MB=$BIG_MB DUP_MB=$DUP_MB DUPES=$DUPES"
echo "================================================================"

for M in "${MOUNTS[@]}"; do
  M="${M%/}"
  echo
  echo "################################################################"
  echo "# $M"
  echo "################################################################"
  if ! mountpoint -q "$M"; then echo "!! $M nie jest zamontowany, pomijam"; SUMMARY+=("$M: nie zamontowany"); continue; fi
  dev=$(findmnt -no SOURCE "$M"); fs=$(findmnt -no FSTYPE "$M")

  section "df (miejsce i i-wezly)"
  df -h "$M"; df -i "$M" | tail -1 | awk '{print "i-wezly: " $3 " / " $2 " (" $5 ")"}'
  res_kb=0
  if [ "$fs" = ext4 ] && have tune2fs; then
    res_kb=$(tune2fs -l "$dev" 2>/dev/null | awk -F: '/^Reserved block count/{r=$2} /^Block size/{b=$2} END{printf "%.0f", r*b/1024}')
    awk -v k="$res_kb" "$HUM"' BEGIN{print "rezerwa root (ext4): " hum(k) "  (tune2fs -m 1 zostawia 1%)"}'
  fi

  section "Skan plikow"
  start=$(date +%s)
  D="$T/$(echo "$M" | tr / _)"; mkdir -p "$D"
  $LOW find "$M" -xdev -type f -printf '%k\t%s\t%TY\t%p\n' 2>/dev/null | awk -F'\t' \
    -v M="$M" -v DEPTH="$DEPTH" -v BIGKB=$((BIG_MB*1024)) -v DUPB=$((DUP_MB*1048576)) -v D="$D" '
    {
      k=$1; s=$2; y=$3; p=$4
      for (i=5;i<=NF;i++) p=p "\t" $i
      files++; tot+=k
      rel=substr(p, length(M)+2); n=split(rel, a, "/")
      if (n==1) { dk[1 "\t(pliki w katalogu glownym)"]+=k; dc[1 "\t(pliki w katalogu glownym)"]++ }
      pre=""
      for (i=1; i<n && i<=DEPTH; i++) { pre=(i==1)?a[1]:pre "/" a[i]; dk[i "\t" pre]+=k; dc[i "\t" pre]++ }
      b=a[n]; e="(brak)"
      if (index(b,".")>1) { e=b; sub(/.*\./,"",e); e=tolower(e); if (length(e)>6 || e ~ /[^a-z0-9]/) e="(inne)" }
      ek[e]+=k; ec[e]++
      yk[y]+=k; yc[y]++
      c=""
      if (b ~ /^\._/) c="AppleDouble ._* (Mac przez Samba)"
      else if (b==".DS_Store" || b=="Thumbs.db" || b=="desktop.ini") c=".DS_Store / Thumbs.db"
      else if (p ~ /\/(\.recycle|\.Trash-[0-9]+|\.Trashes|\$RECYCLE\.BIN|lost\+found)\//) c="kosze, lost+found"
      else if (p ~ /\/(incomplete|\.incomplete)\// || b ~ /\.(part|!qb|crdownload|chunk[0-9]*)$/) c="niedokonczone pobrania"
      else if (b ~ /\.(bak|bkp|old|orig)$/ || b ~ /\.bak-/) c="kopie *.bak / *.old"
      else if (b ~ /\.(iso|img|zip|7z|rar|tar|tgz|gz|xz|zst)$/) c="archiwa i obrazy (zip, tar, iso, img)"
      else if (b ~ /\.log(\.[0-9]+)?$/ || b ~ /-json\.log$/) c="logi *.log"
      if (c!="") { jk[c]+=k; jc[c]++ }
      if (b ~ /^\._/ || b==".DS_Store") ; else {
        if (k>=BIGKB) print k "\t" y "\t" rel > (D "/big")
        if (s>=DUPB && rel !~ /(^|\/)overlay2\// && rel !~ /\/chunks\/[0-9]+$/) print s "\t" b "\t" rel > (D "/dup")
      }
    }
    END{
      printf "%d\t%.0f\n", files, tot > (D "/total")
      for (x in dk) printf "%s\t%.0f\t%d\n", x, dk[x], dc[x] > (D "/dirs")
      for (x in ek) printf "%.0f\t%d\t%s\n", ek[x], ec[x], x > (D "/ext")
      for (x in yk) printf "%s\t%.0f\t%d\n", x, yk[x], yc[x] > (D "/year")
      for (x in jk) printf "%.0f\t%d\t%s\n", jk[x], jc[x], x > (D "/junk")
    }'
  touch "$D/big" "$D/dup" "$D/dirs" "$D/ext" "$D/year" "$D/junk"
  read -r files tot < <(cat "$D/total" 2>/dev/null || echo "0 0")
  awk -v f="$files" -v k="$tot" -v t=$(( $(date +%s) - start )) "$HUM"' BEGIN{printf "plikow: %d, lacznie %s, skan %d s\n", f, hum(k), t}'

  for lvl in $(seq 1 "$DEPTH"); do
    if [ "$lvl" -eq 1 ]; then section "Katalogi, poziom 1 (wszystkie)"; lim=100000; else section "Katalogi, poziom $lvl (top $TOP)"; lim=$TOP; fi
    awk -F'\t' -v L="$lvl" '$1==L{print $3 "\t" $4 "\t" $2}' "$D/dirs" | sort -t$'\t' -k1,1nr | head -n "$lim" |
      awk -F'\t' -v T="$tot" "$HUM"'{printf "%10s %5.1f%% %9d plikow  %s\n", hum($1), (T?100*$1/T:0), $2, $3}'
  done

  section "Typy plikow (top 20)"
  sort -t$'\t' -k1,1nr "$D/ext" | head -20 | awk -F'\t' -v T="$tot" "$HUM"'{printf "%10s %5.1f%% %9d  %s\n", hum($1), (T?100*$1/T:0), $2, $3}'

  section "Rok modyfikacji"
  sort -t$'\t' -k1,1n "$D/year" | awk -F'\t' -v T="$tot" "$HUM"'{printf "%s %10s %5.1f%% %9d plikow\n", $1, hum($2), (T?100*$2/T:0), $3}'

  section "Najwieksze pliki (>= ${BIG_MB} MB, top $TOP)"
  sort -t$'\t' -k1,1nr "$D/big" | head -n "$TOP" | awk -F'\t' "$HUM"'{printf "%10s  %s  %s\n", hum($1), $2, $3}'
  awk -F'\t' "$HUM"'{k+=$1; c++} END{printf "razem: %d plikow, %s\n", c, hum(k)}' "$D/big"

  section "Smieci i kandydaci do usuniecia (wg wzorca nazwy)"
  if [ -s "$D/junk" ]; then sort -t$'\t' -k1,1nr "$D/junk" | awk -F'\t' "$HUM"'{printf "%10s %9d  %s\n", hum($1), $2, $3}'; else echo "brak"; fi
  junk_kb=$(awk -F'\t' '$3 !~ /^archiwa|^logi/{k+=$1} END{printf "%.0f", k}' "$D/junk")
  echo "Szczegoly kategorii:  sudo find $M -xdev -name '._*' | head   (analogicznie inne wzorce)"

  section "Duplikaty: ten sam rozmiar i nazwa (>= ${DUP_MB} MB)"
  cut -f1-3 "$D/dup" | group_dups > "$D/dup_name"
  print_dups "$D/dup_name"
  dupn_kb=$(sum_kb "$D/dup_name")
  awk -v k="$dupn_kb" "$HUM"' BEGIN{print "razem do odzyskania (nazwa+rozmiar): " hum(k)}'

  duph_kb=0
  if [ "$DUPES" = 1 ]; then
    section "Duplikaty po tresci: ten sam rozmiar, md5 z pierwszych i ostatnich 4 MB"
    awk -F'\t' '{c[$1]++; l[NR]=$0} END{for(i=1;i<=NR;i++){split(l[i],q,"\t"); if(c[q[1]]>1) print l[i]}}' "$D/dup" |
      while IFS=$'\t' read -r s _ rel; do
        h=$({ $LOW head -c 4194304 "$M/$rel"; $LOW tail -c 4194304 "$M/$rel"; } 2>/dev/null | md5sum | cut -c1-12)
        printf '%s\tmd5 %s\t%s\n' "$s" "$h" "$rel"
      done | group_dups > "$D/dup_hash"
    print_dups "$D/dup_hash"
    duph_kb=$(sum_kb "$D/dup_hash")
    awk -v k="$duph_kb" "$HUM"' BEGIN{print "razem do odzyskania (tresc): " hum(k) "  - przed usunieciem potwierdz: cmp plik1 plik2"}'
  fi

  section "Usuniete, ale wciaz otwarte pliki (miejsce zwolni sie dopiero po restarcie procesu)"
  del_kb=0; mdev=$(stat -c %d "$M")
  # po numerze urzadzenia, bo kontenery widza te pliki pod swoimi sciezkami (/config/...)
  find /proc/[0-9]*/fd -lname '*(deleted)' -printf '%p\t%l\n' 2>/dev/null |
    while IFS=$'\t' read -r fd tgt; do
      read -r dv sz < <(stat -Lc '%d %s' "$fd" 2>/dev/null) || continue
      [ "$dv" = "$mdev" ] || continue
      pid=${fd#/proc/}; pid=${pid%%/*}
      printf '%s\t%s\t%s\n' "$sz" "$(cat /proc/"$pid"/comm 2>/dev/null)" "$tgt"
    done | sort -t$'\t' -k1,1nr | uniq > "$D/deleted"
  if [ -s "$D/deleted" ]; then
    head -n "$TOP" "$D/deleted" | awk -F'\t' "$HUM"'{printf "%10s  %-15s %s\n", hum($1/1024), $2, $3}'
    del_kb=$(awk -F'\t' '{k+=$1} END{printf "%.0f", k/1024}' "$D/deleted")
  else echo "brak"; fi

  SUMMARY+=("$(df -h --output=pcent,avail "$M" | tail -1 | awk '{print $1 " zajete, " $2 " wolne"}')|$M|$tot|$res_kb|$junk_kb|$dupn_kb|$duph_kb|$del_kb")
done

if have docker && docker info >/dev/null 2>&1; then
  section "Docker: data-root i podkatalogi"
  root=$(docker info -f '{{.DockerRootDir}}')
  echo "data-root: $root ($(findmnt -no TARGET -T "$root"))"
  $LOW du -xsh "$root"/* 2>/dev/null | sort -rh
  [ -d /var/lib/containerd ] && { echo "containerd (karta SD?):"; $LOW du -xsh /var/lib/containerd 2>/dev/null; }

  section "Docker: system df"
  docker system df

  section "Docker: obrazy (najwieksze, * = nieuzywany przez zaden kontener)"
  used=$(docker ps -aq | xargs -r docker inspect -f '{{.Image}}' | sort -u)
  docker images --no-trunc --format '{{.ID}}\t{{.Size}}\t{{.Repository}}:{{.Tag}}' |
    while IFS=$'\t' read -r id sz name; do
      echo "$used" | grep -q "$id" && m="-" || m="*"; printf '%s %8s  %s\n' "$m" "$sz" "$name"
    done | sort -k2 -hr | head -n "$TOP"

  section "Docker: logi kontenerow (json-file)"
  find "$root/containers" -name '*-json.log*' -printf '%s\t%p\n' 2>/dev/null | sort -nr | head -10 |
    while IFS=$'\t' read -r s p; do
      id=$(basename "$(dirname "$p")"); n=$(docker inspect -f '{{.Name}}' "$id" 2>/dev/null)
      awk -v k=$((s/1024)) -v n="${n#/}" -v f="$(basename "$p")" "$HUM"' BEGIN{printf "%10s  %s (%s)\n", hum(k), n, f}'
    done
  echo "limity logow w daemon.json: $(grep -o '"log-opts"[^}]*}' /etc/docker/daemon.json 2>/dev/null || echo brak)"
fi

echo
echo "================================================================"
echo " PODSUMOWANIE (kB -> czytelnie; 'do odzyskania' to gorna granica, sprawdz przed usunieciem)"
echo "================================================================"
for row in "${SUMMARY[@]}"; do
  IFS='|' read -r dfs m tot res junk dupn duph del <<<"$row"
  [ -z "$m" ] && { echo "$dfs"; continue; }
  awk -v m="$m" -v dfs="$dfs" -v t="$tot" -v r="$res" -v j="$junk" -v dn="$dupn" -v dh="$duph" -v d="$del" "$HUM"' BEGIN{
    printf "%-14s %s; pliki %s\n", m, dfs, hum(t)
    printf "    rezerwa root %s | smieci %s | duplikaty nazwa+rozmiar %s | duplikaty tresc %s | usuniete-otwarte %s\n", hum(r), hum(j), hum(dn), (dh>0?hum(dh):"-"), hum(d) }'
done
