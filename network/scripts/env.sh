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
ord_base()  { echo "$ORG_DIR/ordererOrganizations/$1.$DOMAIN_SUFFIX"; }
ord_msp()   { echo "$(ord_base "$1")/orderers/$(ord_host "$1")/msp"; }
ord_tls()   { echo "$(ord_base "$1")/orderers/$(ord_host "$1")/tls"; }
