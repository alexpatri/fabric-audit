#!/usr/bin/env bash
# audit-cli.sh — helper para registrar e consultar logs manualmente (bash ou zsh).
#
# Uso:
#   source network/scripts/audit-cli.sh [org]        # org: hospital (default) | governo | auditoria
#
#   audit_register <operation> <resource> <actor> <conteudo> [prevHash]
#       operation: CREATE | READ | UPDATE | DELETE
#       actor: deve ser user@<orgkey> casando com a org atual (ex.: alice@hospital)
#       <conteudo>: texto; o contentHash (SHA-256) é calculado automaticamente ("" => sem hash)
#       prevHash: para UPDATE/DELETE, use o retorno de audit_last_hash
#   audit_query <actionId>
#   audit_by_resource <resource>
#   audit_by_actor <actor>
#   audit_by_time <inicioRFC3339> <fimRFC3339>
#   audit_last_hash <resource>
#   audit_sha256 <texto>            # utilitário p/ ver o hash de um conteúdo

# Resolve a raiz do repo a partir do caminho deste arquivo (portável bash/zsh).
if [ -n "${BASH_SOURCE:-}" ]; then _self="${BASH_SOURCE[0]}"; else _self="${(%):-%x}"; fi
AUDIT_ROOT="$(cd "$(dirname "$_self")/../.." && pwd)"
export PATH="$AUDIT_ROOT/bin:$PATH"
export FABRIC_CFG_PATH="$AUDIT_ROOT/bin/config"
export FABRIC_LOGGING_SPEC=error

_org="${1:-hospital}"
case "$_org" in
  hospital)  _msp=HospitalMSP;  _port=7051 ;;
  governo)   _msp=GovernoMSP;   _port=9051 ;;
  auditoria) _msp=AuditoriaMSP; _port=11051 ;;
  *) echo "org inválida: $_org (use hospital|governo|auditoria)"; return 1 2>/dev/null || exit 1 ;;
esac

_PO="$AUDIT_ROOT/network/organizations/peerOrganizations"
_OO="$AUDIT_ROOT/network/organizations/ordererOrganizations"
export CORE_PEER_TLS_ENABLED=true
export CORE_PEER_LOCALMSPID="$_msp"
export CORE_PEER_MSPCONFIGPATH="$_PO/$_org.example.com/users/Admin@$_org.example.com/msp"
export CORE_PEER_TLS_ROOTCERT_FILE="$_PO/$_org.example.com/peers/peer0.$_org.example.com/tls/ca.crt"
export CORE_PEER_ADDRESS="localhost:$_port"

# Flags do orderer (qualquer um dos 4 BFT serve) e dos 3 peers endossadores (política AND).
_ord=(-o localhost:7050 --ordererTLSHostnameOverride orderer.hospital.example.com --tls \
      --cafile "$_OO/hospital.example.com/orderers/orderer.hospital.example.com/tls/ca.crt")
_conn=(--peerAddresses localhost:7051  --tlsRootCertFiles "$_PO/hospital.example.com/peers/peer0.hospital.example.com/tls/ca.crt" \
       --peerAddresses localhost:9051  --tlsRootCertFiles "$_PO/governo.example.com/peers/peer0.governo.example.com/tls/ca.crt" \
       --peerAddresses localhost:11051 --tlsRootCertFiles "$_PO/auditoria.example.com/peers/peer0.auditoria.example.com/tls/ca.crt")

audit_sha256() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

audit_register() { # operation resource actor conteudo [prevHash]
  local op="$1" res="$2" actor="$3" conteudo="${4:-}" prev="${5:-}"
  if [ -z "$op" ] || [ -z "$res" ] || [ -z "$actor" ]; then
    echo "uso: audit_register <CREATE|READ|UPDATE|DELETE> <resource> <actor> <conteudo> [prevHash]"; return 1
  fi
  local ch=""; [ -n "$conteudo" ] && ch="$(audit_sha256 "$conteudo")"
  local aid="cli-$(date +%s%N)"
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  peer chaincode invoke "${_ord[@]}" -C audit-channel -n audit-chaincode "${_conn[@]}" \
    --waitForEvent --waitForEventTimeout 150s \
    -c "{\"function\":\"RegisterLog\",\"Args\":[\"$aid\",\"$ts\",\"$op\",\"$res\",\"$actor\",\"$ch\",\"$prev\",\"sess-cli\",\"$(hostname)\"]}" \
    && echo ">> OK  actionId=$aid  contentHash=${ch:-<vazio>}"
}

audit_query()       { peer chaincode query -C audit-channel -n audit-chaincode -c "{\"function\":\"QueryLog\",\"Args\":[\"$1\"]}"; }
audit_by_resource() { peer chaincode query -C audit-channel -n audit-chaincode -c "{\"function\":\"QueryLogsByResource\",\"Args\":[\"$1\"]}"; }
audit_by_actor()    { peer chaincode query -C audit-channel -n audit-chaincode -c "{\"function\":\"QueryLogsByActor\",\"Args\":[\"$1\"]}"; }
audit_by_time()     { peer chaincode query -C audit-channel -n audit-chaincode -c "{\"function\":\"QueryLogsByTimeRange\",\"Args\":[\"$1\",\"$2\"]}"; }
audit_last_hash()   { peer chaincode query -C audit-channel -n audit-chaincode -c "{\"function\":\"GetLastHashForResource\",\"Args\":[\"$1\"]}"; }

echo "audit-cli pronto (org=$_org / $_msp, peer localhost:$_port)."
echo "funções: audit_register | audit_query | audit_by_resource | audit_by_actor | audit_by_time | audit_last_hash | audit_sha256"
