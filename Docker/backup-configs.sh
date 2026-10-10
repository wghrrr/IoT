#!/bin/bash
# Robi jeden zip (z data+godzina w nazwie) z konfiguracji: caly ~/Docker
# (compose/.env/skrypty) + wybrane pliki/katalogi KONFIGURACYJNE spod
# /mnt/Data1T/*_data - celowo NIE dane (bazy, media, TSDB Prometheusa,
# zdjecia immich, pobrane torrenty itp.), bo to duze i odtwarzalne z innych
# zrodel, w przeciwienstwie do configu.
#
# Wymaga: zip (sudo apt install -y zip, jesli brak)
#
# Czesc plikow (np. klucze PKI w hwdsl2_openvpn_data) jest root-owned i
# nieczytelna dla zwyklego usera - uruchamiaj przez sudo:
#   sudo DRY_RUN=1 ./backup-configs.sh
#   sudo ./backup-configs.sh
#
# Uruchom najpierw z DRY_RUN=1, zeby zobaczyc co sie faktycznie zalapie
# (ta lista to punkt startowy - dopasuj do tego co realnie macie na Pi).
set -euo pipefail

# ===== KONFIGURACJA - edytuj wedlug potrzeb =====

# Prawdziwy katalog domowy nawet pod sudo (sudo zwykle przestawia $HOME na
# /root - bez tego INCLUDE_PATHS ponizej wskazywalyby na zly katalog)
if [ -n "${SUDO_USER:-}" ]; then
  REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
  REAL_HOME="$HOME"
fi

# Dyski (te same nazwy zmiennych co w .env uslug)
DATA1T_DIR="${DATA1T_DIR:-/mnt/Data1T}"
DANE4T_DIR="${DANE4T_DIR:-/mnt/Dane4T}"

# Gdzie ladowac gotowe archiwa
DEST_DIR="${DEST_DIR:-$DANE4T_DIR/data4t/backup/docker_config}"

# Tryb "na sucho" - tylko pokazuje co by weszlo do zipa, nic nie zapisuje
DRY_RUN="${DRY_RUN:-0}"

# Powyzej tylu MB dla pojedynczej sciezki dostajesz ostrzezenie (ale wchodzi
# i tak) - zeby zlapac przypadek gdy "config" katalog niespodziewanie
# zawiera cos duzego
WARN_SIZE_MB="${WARN_SIZE_MB:-200}"

# Same sciezki do backupu - tylko KONFIG, nie dane
INCLUDE_PATHS=(
  "$REAL_HOME/Docker"                                    # wszystkie compose/.env/skrypty/CHANGELOG

  # OpenVPN - PKI/certy, male i krytyczne (bez tego trzeba by odtwarzac
  # certyfikaty wszystkim klientom od nowa)
  "$DATA1T_DIR/hwdsl2_openvpn_data"

  # pi-hole - config + blocklisty, bez logow
  "$DATA1T_DIR/pihole_data/etc-pihole"
  "$DATA1T_DIR/pihole_data/etc-dnsmasq.d"

  # Grafana/Prometheus - dashboardy/provisioning + sam config, NIE
  # /mnt/Data1T/grafana_data/data (wewnetrzna baza+cache) ani
  # /mnt/Data1T/prometheus_data (TSDB, dziesiatki GB - to dane)
  "$DATA1T_DIR/grafana_data/provisioning"
  "$DATA1T_DIR/rpi-monitoring_data"

  # Home Assistant - caly config (YAMLe, .storage z integracjami/ZHA/
  # rejestrami encji/dashboardami, zigbee.db, custom_components), bez bazy
  # historii i pochodnych (wykluczenia nizej). Bez .storage przywrocenie
  # po nieudanej aktualizacji nie jest mozliwe.
  "$DATA1T_DIR/homeassistant_data/config"

  # *arr apps - config.xml (bez baz sqlite kolekcji - da sie odbudowac
  # ponownym skanem biblioteki)
  "$DATA1T_DIR/media_data/sonarr_data/config/config.xml"
  "$DATA1T_DIR/media_data/radarr_data/config/config.xml"
  "$DATA1T_DIR/media_data/prowlarr_data/config/config.xml"

  # Immich - tylko klucz API do album-creatora, NIE zdjecia/baza postgres
  "$REAL_HOME/Docker/immich-folder-album-creator/immich_api_key.secret"
)

# Wzorce plikow wykluczane z zipa mimo ze ich katalog nadrzedny jest w
# INCLUDE_PATHS - pochodne/regenerowalne dane albo logi, nie config
EXCLUDE_PATTERNS=(
  "*/etc-pihole/gravity.db"      # skompilowana baza blocklist - regenerowalna przez 'pihole -g'
  "*/etc-pihole/pihole-FTL.db"   # historia zapytan DNS (logi + prywatnosc), nie config
  "*/homeassistant_data/config/home-assistant_v2.db*"  # historia recordera (ok. 0,5 GB), dane
  "*/homeassistant_data/config/backups/*"              # kopie z UI HA, duze
  "*/homeassistant_data/config/deps/*"                 # pakiety pip, HA instaluje je sam
  "*/homeassistant_data/config/.cache/*"
  "*/homeassistant_data/config/tts/*"
  "*/homeassistant_data/config/home-assistant.log*"
  "*/homeassistant_data/config/callgrind.out.*"
  "*/homeassistant_data/config/profile.*.cprof"
)

# ===== KONIEC KONFIGURACJI =====

STAMP=$(date +%Y-%m-%d_%H%M)
ZIP_PATH="${DEST_DIR}/docker-config-backup-${STAMP}.zip"

EXISTING=()
for p in "${INCLUDE_PATHS[@]}"; do
  if [ -e "$p" ]; then
    size_mb=$(du -sm "$p" 2>/dev/null | cut -f1) || true
    echo "OK     ${size_mb:-?}MB   $p"
    if [ "${size_mb:-0}" -gt "$WARN_SIZE_MB" ]; then
      echo "       UWAGA: wiecej niz ${WARN_SIZE_MB}MB - to sporo jak na 'sama konfiguracje', sprawdz czy na pewno ma tu byc" >&2
    fi
    EXISTING+=("$p")
  else
    echo "POMIN (brak)   $p"
  fi
done

if [ "$DRY_RUN" = "1" ]; then
  echo ""
  echo "DRY RUN - nic nie zapisano. Dopasuj INCLUDE_PATHS i uruchom bez DRY_RUN=1."
  exit 0
fi

if [ "${#EXISTING[@]}" -eq 0 ]; then
  echo "Brak istniejacych sciezek do backupu - sprawdz INCLUDE_PATHS." >&2
  exit 1
fi

# archiwum ma trafic na dysk, nie na karte SD - jesli dysk sie nie zamontowal, przerwij
existing="$DEST_DIR"; while [ ! -d "$existing" ]; do existing=$(dirname "$existing"); done
DEST_MOUNT=$(df --output=target "$existing" 2>/dev/null | tail -1)
if [ "$DEST_MOUNT" = "/" ] || [ -z "$DEST_MOUNT" ]; then
  echo "BLAD: ${DEST_DIR} nie lezy na zamontowanym dysku (wyszloby na karte SD) - sprawdz montowanie ${DANE4T_DIR}." >&2
  exit 1
fi
mkdir -p "$DEST_DIR"
if ! zip -r -q "$ZIP_PATH" "${EXISTING[@]}" -x "${EXCLUDE_PATTERNS[@]}"; then
  echo "" >&2
  echo "UWAGA: zip zglosil blad (np. jakis plik nieczytelny dla usera pi, root-owned PKI itp.) - sprawdz czy ${ZIP_PATH} w ogole powstal i czy ma sens." >&2
fi
echo ""
echo "Gotowe: ${ZIP_PATH} ($(du -sh "$ZIP_PATH" 2>/dev/null | cut -f1 || echo '?'))"
