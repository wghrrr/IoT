#!/bin/bash
# Uzycie: ./revokeclient.sh <nazwa_klienta>
set -euo pipefail

CLIENT="${1:?Podaj nazwe klienta do odwolania}"
CONTAINER="${CONTAINER:-openvpn-hwdsl2}"

docker exec -it "${CONTAINER}" ovpn_manage --revokeclient "${CLIENT}" -y
