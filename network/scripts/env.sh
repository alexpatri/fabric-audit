#!/usr/bin/env bash
# env.sh — variáveis compartilhadas da rede (Fase 1).
# Carregado por todos os demais scripts: source "$(dirname "$0")/env.sh"

# ---- Resolução de caminhos (independente do diretório de invocação) ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NETWORK_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$NETWORK_DIR/.." && pwd)"
BIN_DIR="$ROOT_DIR/bin"
ORG_DIR="$NETWORK_DIR/organizations"

# Binários oficiais locais (Fabric v3.1.4 + fabric-ca 1.5.19) têm prioridade no PATH.
export PATH="$BIN_DIR:$PATH"

# ---- Topologia (SPECS §3) ----
DOMAIN_SUFFIX="example.com"
ORGS=(hospital governo auditoria notarial)

declare -A MSPID=(
  [hospital]=HospitalMSP
  [governo]=GovernoMSP
  [auditoria]=AuditoriaMSP
  [notarial]=NotarialMSP
)

# Portas (SPECS §3.3). Porta admin do orderer = porta de serviço + 3 (não consta no SPECS).
declare -A CA_PORT=(   [hospital]=7054 [governo]=8054 [auditoria]=9054 [notarial]=10054 )
declare -A ORD_PORT=(  [hospital]=7050 [governo]=8050 [auditoria]=9050 [notarial]=10050 )
declare -A ADMIN_PORT=([hospital]=7053 [governo]=8053 [auditoria]=9053 [notarial]=10053 )

# ---- Helpers ----
ca_host()   { echo "ca.$1.$DOMAIN_SUFFIX"; }
ord_host()  { echo "orderer.$1.$DOMAIN_SUFFIX"; }
ca_name()   { echo "ca-$1"; }

# Caminhos de material por organização
ca_home()   { echo "$ORG_DIR/fabric-ca/$1"; }
ca_tlscert(){ echo "$(ca_home "$1")/tls-cert.pem"; }                 # TLS do endpoint da CA (p/ --tls.certfiles)
ca_cert()   { echo "$(ca_home "$1")/ca-cert.pem"; }                  # cert de assinatura da CA (raiz do MSP)
ord_base()  { echo "$ORG_DIR/ordererOrganizations/$1.$DOMAIN_SUFFIX"; }
ord_msp()   { echo "$(ord_base "$1")/orderers/$(ord_host "$1")/msp"; }
ord_tls()   { echo "$(ord_base "$1")/orderers/$(ord_host "$1")/tls"; }
ord_org_msp(){ echo "$(ord_base "$1")/msp"; }                        # MSP nível-org (grupo Orderer do canal)

# ---- Fase 2: peers / aplicação ----
APP_ORGS=(hospital governo auditoria)
declare -A PEER_PORT=(   [hospital]=7051  [governo]=9051  [auditoria]=11051 )
declare -A PEER_CC_PORT=([hospital]=7052  [governo]=9052  [auditoria]=11052 )
declare -A COUCH_PORT=(  [hospital]=5984  [governo]=6984  [auditoria]=7984  )

peer_host()     { echo "peer0.$1.$DOMAIN_SUFFIX"; }
couch_host()    { echo "couchdb.$1"; }
peer_base()     { echo "$ORG_DIR/peerOrganizations/$1.$DOMAIN_SUFFIX"; }
peer_org_msp()  { echo "$(peer_base "$1")/msp"; }                    # MSP nível-org (grupo Application do canal)
peer_node_msp() { echo "$(peer_base "$1")/peers/$(peer_host "$1")/msp"; }
peer_node_tls() { echo "$(peer_base "$1")/peers/$(peer_host "$1")/tls"; }
peer_tls_ca()   { echo "$(peer_node_tls "$1")/ca.crt"; }
admin_msp()     { echo "$(peer_base "$1")/users/Admin@$1.$DOMAIN_SUFFIX/msp"; }

# ---- Fase 3: chaincode / lifecycle ----
CHANNEL="audit-channel"
CC_NAME="audit-chaincode"
CC_VERSION="1.1"   # Fase 4: validações completas + queries + índices (upgrade)
CC_SEQUENCE="2"
CC_LABEL="${CC_NAME}_${CC_VERSION}"
CC_POLICY="AND('HospitalMSP.peer','GovernoMSP.peer','AuditoriaMSP.peer')"

# Orderer usado para submeter transações (qualquer um dos 4 BFT serve).
ORDERER_ENDPOINT="localhost:7050"
ORDERER_OVERRIDE="orderer.hospital.example.com"
orderer_ca() { echo "$(ord_tls hospital)/ca.crt"; }

# Configura o ambiente do CLI `peer` para agir como Admin@<org>.
set_peer_globals() {
  local org="$1"
  export FABRIC_CFG_PATH="$BIN_DIR/config"
  export FABRIC_LOGGING_SPEC=error
  export CORE_PEER_TLS_ENABLED=true
  export CORE_PEER_LOCALMSPID="${MSPID[$org]}"
  export CORE_PEER_TLS_ROOTCERT_FILE="$(peer_tls_ca "$org")"
  export CORE_PEER_MSPCONFIGPATH="$(admin_msp "$org")"
  export CORE_PEER_ADDRESS="localhost:${PEER_PORT[$org]}"
}

# Monta os argumentos --peerAddresses/--tlsRootCertFiles dos 3 peers de aplicação.
peer_conn_args() {
  local args=()
  for o in "${APP_ORGS[@]}"; do
    args+=(--peerAddresses "localhost:${PEER_PORT[$o]}" --tlsRootCertFiles "$(peer_tls_ca "$o")")
  done
  echo "${args[@]}"
}
