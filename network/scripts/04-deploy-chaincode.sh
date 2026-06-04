#!/usr/bin/env bash
# 04-deploy-chaincode.sh — empacota, instala (3 peers), aprova (3 orgs) e faz commit do
# chaincode `audit-chaincode` com a política AND('HospitalMSP.peer','GovernoMSP.peer','AuditoriaMSP.peer').
# Builder tradicional: o peer compila/sobe o container do chaincode via ccenv+baseos.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"
cd "$NETWORK_DIR"

export FABRIC_CFG_PATH="$BIN_DIR/config"   # core.yaml (necessário já no package)
export FABRIC_LOGGING_SPEC=error
CC_SRC="$ROOT_DIR/chaincode/audit"
PKG="$NETWORK_DIR/${CC_LABEL}.tar.gz"
ORD=(-o "$ORDERER_ENDPOINT" --ordererTLSHostnameOverride "$ORDERER_OVERRIDE" --tls --cafile "$(orderer_ca)")

# 0) Garante deps vendorizadas (build offline no ccenv).
echo ">> go mod vendor (deps hermetizadas)"
( cd "$CC_SRC" && go mod vendor )

# 1) Empacota o chaincode (fonte + vendor).
echo ">> package: $PKG"
peer lifecycle chaincode package "$PKG" --path "$CC_SRC" --lang golang --label "$CC_LABEL"

# 2) Instala em cada peer de aplicação (o peer compila no ccenv).
for org in "${APP_ORGS[@]}"; do
  set_peer_globals "$org"
  echo ">> install em peer0.$org (pode levar ~1min na 1ª compilação)..."
  peer lifecycle chaincode install "$PKG" 2>&1 | grep -vE "already successfully installed" || true
done

# 3) Package ID (determinístico a partir do pacote).
PACKAGE_ID="$(peer lifecycle chaincode calculatepackageid "$PKG" | tail -n1)"
echo ">> PACKAGE_ID=$PACKAGE_ID"

# 4) Aprova por cada organização.
for org in "${APP_ORGS[@]}"; do
  set_peer_globals "$org"
  echo ">> approveformyorg: $org"
  peer lifecycle chaincode approveformyorg "${ORD[@]}" \
    --channelID "$CHANNEL" --name "$CC_NAME" --version "$CC_VERSION" \
    --package-id "$PACKAGE_ID" --sequence "$CC_SEQUENCE" \
    --signature-policy "$CC_POLICY"
done

# 5) Verifica prontidão para commit (espera 3× true).
echo ">> checkcommitreadiness"
set_peer_globals hospital
peer lifecycle chaincode checkcommitreadiness \
  --channelID "$CHANNEL" --name "$CC_NAME" --version "$CC_VERSION" --sequence "$CC_SEQUENCE" \
  --signature-policy "$CC_POLICY" --output json

# 6) Commit (um peer por org).
echo ">> commit"
read -ra CONN <<< "$(peer_conn_args)"
peer lifecycle chaincode commit "${ORD[@]}" \
  --channelID "$CHANNEL" --name "$CC_NAME" --version "$CC_VERSION" --sequence "$CC_SEQUENCE" \
  --signature-policy "$CC_POLICY" "${CONN[@]}"

# 7) Confirma.
echo ">> querycommitted"
peer lifecycle chaincode querycommitted --channelID "$CHANNEL" --name "$CC_NAME"

echo ">> Fase 3: chaincode '$CC_NAME' v$CC_VERSION (seq $CC_SEQUENCE) committed com política AND."
