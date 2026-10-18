#!/bin/bash
# power-profile.sh - profil poboru mocy urzadzenia z historii Prometheusa
# (metryki HA, co 15 s). Dzieli historie na cykle (np. pranie, suszenie) i dla
# kazdego pokazuje: start, koniec, czas, max W, energie, przerwy w trakcie
# (ile, najdluzsza, jaka moc w przerwie) oraz moc spoczynkowa poza cyklami.
# Sluzy do dobrania progow automatyzacji start/koniec w HA. Tylko czyta.
#
# Uzycie (na RPi):
#   sudo ./power-profile.sh sensor.g_pralka_nowa_active_power
#   sudo DAYS=30 ./power-profile.sh sensor.g_suszarka_piwnica_active_power
#   sudo DETAIL=1 ./power-profile.sh sensor.g_pralka_nowa_active_power   # + przebieg kazdego cyklu
#
# Zmienne: DAYS (14) zakres historii, STEP (15) krok w s, ACTIVE_W (3) moc,
# powyzej ktorej "cos sie dzieje", GAP_MIN (30) przerwa ponizej ACTIVE_W
# dzielaca cykle, MIN_CYCLE_MIN (3) krotsze aktywnosci pomijane,
# PROM_URL (http://localhost:9090).
# Haslo Prometheusa: plik prom_password z katalogu konfiguracji kontenera
# monitoring-prometheus (uzytkownik admin) - nie trafia do wyniku.

E="${1:?Podaj encje, np. sensor.g_pralka_nowa_active_power}"
DAYS="${DAYS:-14}"
STEP="${STEP:-15}"
ACTIVE_W="${ACTIVE_W:-3}"
GAP_MIN="${GAP_MIN:-30}"
MIN_CYCLE_MIN="${MIN_CYCLE_MIN:-3}"
DETAIL="${DETAIL:-0}"
PROM_URL="${PROM_URL:-http://localhost:9090}"

[ "$(id -u)" -eq 0 ] || { echo "Uruchom przez sudo" >&2; exit 1; }
for b in curl jq awk; do command -v $b >/dev/null || { echo "Brak: $b" >&2; exit 1; }; done

CFG=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/prometheus"}}{{.Source}}{{end}}{{end}}' monitoring-prometheus 2>/dev/null)
[ -r "$CFG/prom_password" ] || { echo "Nie znaleziono prom_password (kontener monitoring-prometheus)" >&2; exit 1; }
# login przez -K (stdin), zeby haslo nie bylo widoczne w liscie procesow
prom() { printf 'user = "admin:%s"\n' "$(cat "$CFG/prom_password")" | curl -sfG -K - "$PROM_URL/api/v1/$1" "${@:2}"; }

Q="{__name__=~\"hass_sensor_power_w(att)?\",entity=\"$E\"}"
END=$(date +%s)
START=$((END - DAYS * 86400))

# Prometheus oddaje max 11000 punktow na zapytanie - pobieramy dobami
DATA=$(
  t=$START
  while [ "$t" -lt "$END" ]; do
    e=$((t + 86400)); [ "$e" -gt "$END" ] && e=$END
    prom query_range --data-urlencode "query=$Q" -d "start=$t" -d "end=$e" -d "step=$STEP" \
      | jq -r '.data.result[0].values[]? | "\(.[0] | floor) \(.[1])"'
    t=$((e + STEP))
  done
)
if [ -z "$DATA" ]; then
  echo "Brak danych dla $E. Metryki tej encji w Prometheusie:" >&2
  prom series --data-urlencode "match[]={entity=\"$E\"}" | jq -r '.data[].__name__' | sort -u >&2
  exit 1
fi

echo "=== $E: $DAYS dni, krok ${STEP}s, aktywnosc > ${ACTIVE_W} W, cykle dzieli ${GAP_MIN} min ciszy ==="
echo "$DATA" | awk -v step="$STEP" -v aw="$ACTIVE_W" -v gap="$((GAP_MIN * 60))" \
  -v minc="$((MIN_CYCLE_MIN * 60))" -v detail="$DETAIL" '
function ts(t) { return strftime("%m-%d %H:%M", t) }
function band(v) { return v <= aw ? "cisza" : v < 50 ? "<50W" : v < 500 ? "50-500W" : v < 1500 ? "500-1500W" : ">=1500W" }
function flush_cycle(   d, i) {
  if (!inc) return
  d = last_act - c_start + step
  if (d >= minc) {
    n++
    printf "%2d. %s -> %s  %4d min  max %5.0f W  %6.0f Wh  przerw>=1min: %2d  najdluzsza: %3d min  moc w przerwach: %s  po koncu: %s\n",
      n, ts(c_start), strftime("%H:%M", last_act), d / 60, c_max, c_wh, np, pmax / 60,
      (pvmin == "" ? "-" : sprintf("%.1f-%.1f W", pvmin, pvmax)), (tmin == "" ? "-" : sprintf("%.1f-%.1f W", tmin, tmax))
    if (detail) for (i = 1; i <= nseg; i++) print "      " seg[i]
  } else short++
  inc = 0
}
function seg_close() { if (sb != "" && inc) seg[++nseg] = sprintf("%s %-9s %4d min  (%.1f-%.1f W)", strftime("%H:%M", ss), sb, (sl - ss + step) / 60, smin, smax) }
{
  t = $1; v = $2 + 0
  if (prev_t != "" && t - prev_t > 4 * step) holes += (t - prev_t) / 60
  prev_t = t
  if (v > aw) {
    if (inc && t - last_act > gap) { seg_close(); flush_cycle() }
    if (!inc) { inc = 1; c_start = t; c_max = 0; c_wh = 0; np = 0; pmax = 0; pvmin = ""; pvmax = ""; tmin = ""; tmax = ""; nseg = 0; sb = ""; pause_s = "" }
    if (pause_s != "") {
      pd = t - pause_s; if (pd >= 60) np++; if (pd > pmax) pmax = pd; pause_s = ""
      if (pvmin == "" || tmin < pvmin) pvmin = tmin; if (pvmax == "" || tmax > pvmax) pvmax = tmax; tmin = ""; tmax = ""
    }
    last_act = t; if (v > c_max) c_max = v
  } else {
    if (inc && t - last_act > gap) { seg_close(); flush_cycle() }
    if (inc) {
      if (pause_s == "") pause_s = t
      if (tmin == "" || v < tmin) tmin = v; if (tmax == "" || v > tmax) tmax = v
    } else {
      iv[++ni] = v
    }
  }
  if (inc) {
    c_wh += v * step / 3600
    b = band(v)
    if (b != sb) { seg_close(); sb = b; ss = t; smin = v; smax = v }
    sl = t; if (v < smin) smin = v; if (v > smax) smax = v
  }
}
END {
  seg_close(); flush_cycle()
  if (!n) print "Brak cykli."
  if (short) printf "(pominieto %d krotkich aktywnosci < min. czasu cyklu)\n", short
  if (ni) {
    for (i = 1; i <= ni; i++) { k = sprintf("%.1f", iv[i]); cnt[k]++ }
    printf "Moc poza cyklami (wartosc W: %% probek):"
    for (k in cnt) if (cnt[k] * 100 / ni >= 1) printf "  %s: %.0f%%", k, cnt[k] * 100 / ni
    print ""
  }
  if (holes > 30) printf "Luki w danych (HA lub gniazdko niedostepne): ok. %.0f min\n", holes
}'
