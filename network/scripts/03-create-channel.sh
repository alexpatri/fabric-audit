#!/usr/bin/env bash
# 03-create-channel.sh — cria o canal `audit-channel` (BFT) e faz os 3 peers ingressarem.
#   1) configtxgen gera o bloco gênese      2) osnadmin channel join nos 4 orderers
#   3) aguarda status 'active' (quorum 3/4)  4) sobe CouchDBs+peers  5) peer channel join
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"
cd "$NETWORK_DIR"

CHANNEL="audit-channel"
BLOCK="$NETWORK_DIR/system-genesis-block/$CHANNEL.block"

osn() {  # osn <org> <args...>
  local org="$1"; shift
  local tls; tls="$(ord_tls "$org")"
  osnadmin "$@" -o "localhost:${ADMIN_PORT[$org]}" \
    --ca-file "$tls/ca.crt" --client-cert "$tls/server.crt" --client-key "$tls/server.key"
}

# 0) (Re)cria os orderers para aplicar as variáveis de cluster BFT.
echo ">> Recriando orderers (aplica ORDERER_GENERAL_CLUSTER_*)..."
docker compose up -d \
  orderer.hospital.example.com orderer.governo.example.com \
  orderer.auditoria.example.com orderer.notarial.example.com

# 1) Bloco gênese do canal.
echo ">> configtxgen: gerando bloco gênese de $CHANNEL"
mkdir -p "$NETWORK_DIR/system-genesis-block"
FABRIC_CFG_PATH="$NETWORK_DIR/configtx" \
  configtxgen -profile AuditChannel -channelID "$CHANNEL" -outputBlock "$BLOCK"

# 2) Join dos 4 orderers (channel participation).
for org in "${ORGS[@]}"; do
  echo ">> osnadmin channel join: orderer.$org"
  osn "$org" channel join --channelID "$CHANNEL" --config-block "$BLOCK"
done

# 3) Espera o canal ficar 'active' em cada orderer.
echo ">> Aguardando status 'active' (quorum BFT 3/4)..."
for org in "${ORGS[@]}"; do
  ok=""
  for _ in $(seq 1 30); do
    if osn "$org" channel list --channelID "$CHANNEL" 2>/dev/null | grep -q '"status": *"active"'; then
      ok=1; break
    fi
    sleep 2
  done
  [ -n "$ok" ] && echo "   orderer.$org: active" || echo "   orderer.$org: ainda não active (segue mesmo assim)"
done

# 4) Sobe CouchDBs e peers.
echo ">> Subindo CouchDBs e peers..."
docker compose up -d \
  couchdb.hospital couchdb.governo couchdb.auditoria \
  peer0.hospital.example.com peer0.governo.example.com peer0.auditoria.example.com

# 5) peer channel join (CLI no host).
export FABRIC_CFG_PATH="$BIN_DIR/config"   # core.yaml
export FABRIC_LOGGING_SPEC=error           # silencia logs gRPC/INFO do CLI no host
for org in "${APP_ORGS[@]}"; do
  echo ">> peer channel join: peer0.$org"
  export CORE_PEER_TLS_ENABLED=true
  export CORE_PEER_LOCALMSPID="${MSPID[$org]}"
  export CORE_PEER_TLS_ROOTCERT_FILE="$(peer_node_tls "$org")/ca.crt"
  export CORE_PEER_MSPCONFIGPATH="$(admin_msp "$org")"
  export CORE_PEER_ADDRESS="localhost:${PEER_PORT[$org]}"
  ok=""
  for _ in $(seq 1 30); do
    if peer channel join -b "$BLOCK" 2>/dev/null; then ok=1; break; fi
    sleep 2
  done
  [ -n "$ok" ] && echo "   peer0.$org ingressou" || { echo "ERRO: peer0.$org não ingressou" >&2; exit 1; }
done

echo ">> Fase 2: canal '$CHANNEL' criado; os 3 peers ingressaram."
