#!/bin/bash
# ha-dump.sh - zrzut konfiguracji Home Assistant do przegladu (automatyzacje,
# skrypty, szablony, pomocnicy, lista encji). Tylko czyta.
#
# Uzycie (na RPi):
#   sudo ./ha-dump.sh > ~/ha-dump.txt
#   sudo STATES=0 ./ha-dump.sh > ~/ha-dump.txt   # bez biezacych stanow encji (krocej)
# Potem na Macu:
#   scp pi@<IP_RPI>:~/ha-dump.txt "Pliki in/"
# i usun plik z RPi: rm ~/ha-dump.txt
#
# Maskowane: secrets.yaml (pomijany), klucze password/token/secret/api_key/
# webhook_id/..., latitude/longitude/elevation, JWT i dlugie ciagi base64.
# Nazwy encji, urzadzen i pomieszczen zostaja - plik do rozmowy, nie do repo.

STATES="${STATES:-1}"
CT=homeassistant

[ "$(id -u)" -eq 0 ] || { echo "Uruchom przez sudo" >&2; exit 1; }
C=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/config"}}{{.Source}}{{end}}{{end}}' "$CT" 2>/dev/null)
[ -d "$C" ] || { echo "Nie znaleziono katalogu /config kontenera $CT" >&2; exit 1; }

M='s/^([[:space:]-]*[A-Za-z0-9_]*(password|passwd|secret|token|credentials|bearer|authorization|api_?key|webhook_id|latitude|longitude|elevation)[A-Za-z0-9_]*["]?[[:space:]]*[:=][[:space:]]*).+$/\1***/I; s/eyJ[A-Za-z0-9_.-]+/***JWT***/g; s/[A-Za-z0-9+\/_=-]{40,}/***B64***/g'
mask() { sed -E "$M"; }

echo "################################################################"
echo "# HA dump - $(date '+%Y-%m-%d %H:%M')  wersja: $(cat "$C/.HA_VERSION" 2>/dev/null)"
echo "################################################################"

echo
echo "=== Pliki YAML (bez secrets.yaml, kopii i katalogow technicznych) ==="
find "$C" -maxdepth 3 -type f \( -name '*.yaml' -o -name '*.yml' \) \
  -not -name 'secrets.yaml' \
  -not -path '*/.storage/*' -not -path '*/custom_components/*' -not -path '*/blueprints/*' \
  -not -path '*/deps/*' -not -path '*/.cache/*' -not -path '*/tts/*' -not -path '*/backups/*' \
  | sort | while read -r f; do
    echo
    echo "----- ${f#"$C"/}  ($(wc -l < "$f") linii) -----"
    mask < "$f"
  done

echo
echo "=== Blueprinty (tylko nazwy plikow) ==="
find "$C/blueprints" -type f -name '*.yaml' 2>/dev/null | sed "s|^$C/||" | sort

echo
echo "=== Pomocnicy i szablony z UI (.storage) ==="
python3 - "$C/.storage" <<'PY' | mask
import json, os, sys
S = sys.argv[1]
def load(n):
    try: return json.load(open(os.path.join(S, n)))["data"]
    except (OSError, ValueError, KeyError): return None
for dom in ["input_boolean", "input_number", "input_select", "input_text", "input_datetime",
            "input_button", "counter", "timer", "schedule"]:
    d = load(dom)
    items = (d or {}).get("items", [])
    if items:
        print(f"\n-- {dom} ({len(items)})")
        for i in items:
            extra = {k: v for k, v in i.items() if k not in ("id", "name", "icon")}
            print(f"  {dom}.{i.get('id')}  \"{i.get('name')}\"  {json.dumps(extra, ensure_ascii=False)}")
ce = load("core.config_entries") or {}
helpers = [e for e in ce.get("entries", []) if e.get("domain") in
           ("template", "group", "derivative", "integration", "utility_meter", "statistics",
            "threshold", "min_max", "trend", "filter", "switch_as_x", "history_stats", "tod")]
if helpers:
    print(f"\n-- pomocnicy z config entries ({len(helpers)})")
    for e in helpers:
        print(f"  [{e['domain']}] \"{e.get('title')}\"  {json.dumps(e.get('options', {}), ensure_ascii=False)}")
PY

echo
echo "=== Encje (rejestr): entity_id | platforma | nazwa | klasa/jednostka | wylaczona ==="
python3 - "$C/.storage/core.entity_registry" <<'PY' | mask
import json, sys
from collections import Counter
ents = json.load(open(sys.argv[1]))["data"]["entities"]
print("encji:", len(ents), " wg domeny:", dict(Counter(e["entity_id"].split(".")[0] for e in ents).most_common()))
for e in sorted(ents, key=lambda e: e["entity_id"]):
    cls = e.get("device_class") or e.get("original_device_class") or ""
    unit = e.get("unit_of_measurement") or ""
    dis = e.get("disabled_by") or ""
    name = e.get("name") or e.get("original_name") or ""
    print(f"{e['entity_id']} | {e.get('platform')} | {name} | {cls} {unit} | {dis}")
PY

if [ "$STATES" = "1" ]; then
  echo
  echo "=== Automatyzacje i skrypty: stan i ostatnie uruchomienie (core.restore_state) ==="
  python3 - "$C/.storage/core.restore_state" <<'PY' | mask
import json, sys
for r in sorted(json.load(open(sys.argv[1]))["data"], key=lambda r: r["state"]["entity_id"]):
    st = r["state"]; eid = st["entity_id"]
    if eid.split(".")[0] in ("automation", "script"):
        a = st.get("attributes", {})
        print(f"{eid} = {st['state']}  last_triggered={a.get('last_triggered')}  mode={a.get('mode')}")
PY
fi

echo
echo "=== Identyfikatory z YAML (device_id / entity_id w akcjach urzadzen) -> encje ==="
python3 - "$C" <<'PY' | mask
import glob, json, os, re, sys
C = sys.argv[1]
txt = "".join(open(f, encoding="utf-8").read() for f in glob.glob(os.path.join(C, "*.yaml"))
              if not f.endswith("secrets.yaml"))
ids = set(re.findall(r"\b[0-9a-f]{32}\b", txt))
ents = json.load(open(os.path.join(C, ".storage/core.entity_registry")))["data"]["entities"]
devs = {d["id"]: d for d in json.load(open(os.path.join(C, ".storage/core.device_registry")))["data"]["devices"]}
for e in ents:
    if e["id"] in ids:
        print(f"encja    {e['id']} -> {e['entity_id']}")
for i in sorted(ids & devs.keys()):
    d = devs[i]
    names = [e["entity_id"] for e in ents if e.get("device_id") == i and not e.get("disabled_by")]
    print(f"urzadz.  {i} -> {d.get('name_by_user') or d.get('name')}: {', '.join(names[:8])}")
miss = ids - devs.keys() - {e["id"] for e in ents}
for i in sorted(miss): print(f"BRAK     {i} (nie ma w rejestrze - akcja nie zadziala)")
PY

echo
echo "=== Bledy automatyzacji i skryptow w logu (7 dni) ==="
docker logs --since 168h "$CT" 2>&1 | sed -E 's/\x1b\[[0-9;]*m//g' \
  | grep -E 'components\.(automation|script|template)' | grep -E 'WARNING|ERROR' | cut -c1-260 | mask | tail -40

echo
echo "# koniec"
