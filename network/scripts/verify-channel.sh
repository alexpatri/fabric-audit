#!/usr/bin/env bash
# verify-channel.sh — critério de aceitação da Fase 2 (SPECS §11.2):
# 'peer channel list' em cada peer deve mostrar 'audit-channel'.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

export FABRIC_CFG_PATH="$BIN_DIR/config"
export FABRIC_LOGGING_SPEC=error   # silencia logs gRPC/INFO do CLI no host
CHANNEL="audit-channel"
rc=0
for org in "${APP_ORGS[@]}"; do
  export CORE_PEER_TLS_ENABLED=true
  export CORE_PEER_LOCALMSPID="${MSPID[$org]}"
  export CORE_PEER_TLS_ROOTCERT_FILE="$(peer_node_tls "$org")/ca.crt"
  export CORE_PEER_MSPCONFIGPATH="$(admin_msp "$org")"
  export CORE_PEER_ADDRESS="localhost:${PEER_PORT[$org]}"
  echo "== peer0.$org (localhost:${PEER_PORT[$org]}) =="
  out="$(peer channel list 2>&1)"
  echo "$out" | sed 's/^/   /'
  if echo "$out" | grep -q "$CHANNEL"; then echo "   -> OK"; else echo "   -> FALHA"; rc=1; fi
done

if [ "$rc" -eq 0 ]; then
  echo ">> CRITÉRIO FASE 2 ATENDIDO: os 3 peers listam '$CHANNEL'."
else
  echo ">> CRITÉRIO FASE 2 NÃO ATENDIDO." >&2
fi
exit "$rc"
