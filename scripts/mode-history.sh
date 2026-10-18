#!/bin/bash
# mode-history.sh - historia przelacznika (input_boolean, switch, binary_sensor)
# z Prometheusa (metryki HA, co 15 s) na tle temperatury i progu. Dla kazdej
# zmiany stanu: czas, nowy stan, jak dlugo trwal poprzedni, temperatura i prog
# w tej chwili. Potem dobowo: min/srednia/max temperatury, czas w stanie "on",
# liczba zmian. Sluzy do oceny, czy tryb grzejnika przelacza sie z pogoda,
# czy z pora dnia. Tylko czyta. Recorder HA trzyma 3 dni, Prometheus duzo dluzej.
#
# Uzycie (na RPi):
#   sudo ./mode-history.sh
#   sudo DAYS=90 ./mode-history.sh
#   sudo ./mode-history.sh input_boolean.uwzgledniaj_czas_grzejnika sensor.vicare_outside_temperature input_number.temp_graniczna_auto
#
# Argumenty (domyslne jak wyzej): encja przelacznika, encja temperatury, encja
# progu (input_number; "-" = bez progu).
# Zmienne: DAYS (60) zakres historii, STEP (60) krok w s,
# PROM_URL (http://localhost:9090).
# Haslo Prometheusa: plik prom_password z katalogu konfiguracji kontenera
# monitoring-prometheus (uzytkownik admin) - nie trafia do wyniku.

E="${1:-input_boolean.uwzgledniaj_czas_grzejnika}"
T="${2:-sensor.vicare_outside_temperature}"
P="${3:-input_number.temp_graniczna_auto}"
DAYS="${DAYS:-60}"
STEP="${STEP:-60}"
PROM_URL="${PROM_URL:-http://localhost:9090}"

[ "$(id -u)" -eq 0 ] || { echo "Uruchom przez sudo" >&2; exit 1; }
for b in curl jq awk; do command -v $b >/dev/null || { echo "Brak: $b" >&2; exit 1; }; done

CFG=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/prometheus"}}{{.Source}}{{end}}{{end}}' monitoring-prometheus 2>/dev/null)
[ -r "$CFG/prom_password" ] || { echo "Nie znaleziono prom_password (kontener monitoring-prometheus)" >&2; exit 1; }
# login przez -K (stdin), zeby haslo nie bylo widoczne w liscie procesow
prom() { printf 'user = "admin:%s"\n' "$(cat "$CFG/prom_password")" | curl -sfG -K - "$PROM_URL/api/v1/$1" "${@:2}"; }

END=$(date +%s)
START=$((END - DAYS * 86400))

# Prometheus oddaje max 11000 punktow na zapytanie - pobieramy po 7 dni
fetch() {
  local q="$1" t=$START e
  while [ "$t" -lt "$END" ]; do
    e=$((t + 7 * 86400)); [ "$e" -gt "$END" ] && e=$END
    prom query_range --data-urlencode "query=$q" -d "start=$t" -d "end=$e" -d "step=$STEP" \
      | jq -r '.data.result[0].values[]? | "\(.[0] | floor) \(.[1])"'
    t=$((e + STEP))
  done
}
series() {
  echo "Brak danych dla $1. Metryki tej encji w Prometheusie:" >&2
  prom series --data-urlencode "match[]={entity=\"$1\"}" | jq -r '.data[].__name__' | sort -u >&2
}

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fetch "{__name__=~\"hass_(input_boolean|switch|binary_sensor)_state\",entity=\"$E\"}" > "$TMP/e"
[ -s "$TMP/e" ] || { series "$E"; exit 1; }
fetch "{__name__=~\"hass_sensor_temperature.*\",entity=\"$T\"}" > "$TMP/t"
[ -s "$TMP/t" ] || series "$T"
: > "$TMP/p"
[ "$P" != "-" ] && { fetch "{__name__=\"hass_input_number_state\",entity=\"$P\"}" > "$TMP/p"; [ -s "$TMP/p" ] || series "$P"; }

echo "=== $E: $DAYS dni, krok ${STEP}s, temperatura: $T, prog: $P ==="
echo "dane od: $(date -d @"$(head -1 "$TMP/e" | cut -d' ' -f1)" '+%F %H:%M')"
echo
awk -v step="$STEP" '
function ts(t) { return strftime("%Y-%m-%d %H:%M", t) }
function dur(s) { return s >= 86400 ? sprintf("%dd %2dh", s / 86400, (s % 86400) / 3600) : sprintf("%2dh %02dm", s / 3600, (s % 3600) / 60) }
function num(a, t) { return (t in a) ? sprintf("%5.1f", a[t]) : "    -" }
FILENAME ~ /\/t$/ { temp[$1] = $2; next }
FILENAME ~ /\/p$/ { prog[$1] = $2; next }
{
  t = $1; v = ($2 + 0 > 0) ? "on" : "off"
  if (prev_t != "" && t - prev_t > 10 * step) {
    printf "  (brak danych %s -> %s, %s)\n", ts(prev_t), ts(t), dur(t - prev_t)
    holes += t - prev_t
  }
  if (state == "") printf "%s  start: %-3s                     temp %s  prog %s\n", ts(t), v, num(temp, t), num(prog, t)
  else if (v != state) {
    n++
    printf "%s  -> %-3s  (poprzedni %s)  temp %s  prog %s\n", ts(t), v, dur(t - since), num(temp, t), num(prog, t)
    ch[strftime("%Y-%m-%d", t)]++
  }
  if (v != state) { state = v; since = t }
  d = strftime("%Y-%m-%d", t)
  if (!(d in seen)) { seen[d] = 1; days[++nd] = d }
  if (v == "on") on[d] += step
  if (t in temp) { x = temp[t]; s[d] += x; c[d]++; if (!(d in mn) || x < mn[d]) mn[d] = x; if (!(d in mx) || x > mx[d]) mx[d] = x }
  prev_t = t
}
END {
  printf "\nteraz: %s od %s (%s), zmian lacznie: %d, brak danych lacznie: %s\n\n", state, ts(since), dur(prev_t - since), n, dur(holes)
  print "dzien        temp min  sred   max   'on'    zmian"
  for (i = 1; i <= nd; i++) {
    d = days[i]
    printf "%s  %5s  %5s  %5s  %5.1fh  %3d\n", d,
      (d in mn) ? sprintf("%5.1f", mn[d]) : "-", c[d] ? sprintf("%5.1f", s[d] / c[d]) : "-",
      (d in mx) ? sprintf("%5.1f", mx[d]) : "-", on[d] / 3600, ch[d]
  }
}' "$TMP/t" "$TMP/p" "$TMP/e"
