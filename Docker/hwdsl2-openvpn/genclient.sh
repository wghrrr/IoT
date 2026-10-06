#!/bin/bash
# Uzycie: ./genclient.sh <nazwa_klienta>
# Dodaje klienta i zapisuje gotowy .ovpn obok siebie.
set -euo pipefail

CLIENT="${1:?Podaj nazwe klienta, np. laptop / telefon / tablet}"
CONTAINER="${CONTAINER:-openvpn-hwdsl2}"

docker exec "${CONTAINER}" ovpn_manage --addclient "${CLIENT}"
docker exec "${CONTAINER}" ovpn_manage --exportclient "${CLIENT}" > "${CLIENT}.ovpn"

echo "Gotowe: $(pwd)/${CLIENT}.ovpn"
echo "Przenies plik na urzadzenie (AirDrop na Mac/iPad/iPhone) i otworz w OpenVPN Connect."
