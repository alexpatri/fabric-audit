#!/usr/bin/env bash
# verify-orderers.sh — critério de aceitação da Fase 1 (SPECS §11.1):
# 'osnadmin channel list' responde corretamente para os 4 ordenadores.
# Espera-se HTTP 200 + {"systemChannel":null,"channels":[]} em cada um (sem canal nesta fase).
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

rc=0
for org in "${ORGS[@]}"; do
  adminport="${ADMIN_PORT[$org]}"
  tls="$(ord_tls "$org")"
  echo "== orderer.$org (admin localhost:$adminport) =="
  if osnadmin channel list \
       -o "localhost:$adminport" \
       --ca-file   "$tls/ca.crt" \
       --client-cert "$tls/server.crt" \
       --client-key  "$tls/server.key"; then
    echo "   -> OK"
  else
    echo "   -> FALHA"
    rc=1
  fi
done

if [ "$rc" -eq 0 ]; then
  echo ">> CRITÉRIO FASE 1 ATENDIDO: os 4 ordenadores respondem a 'osnadmin channel list'."
else
  echo ">> CRITÉRIO FASE 1 NÃO ATENDIDO: ao menos um ordenador falhou." >&2
fi
exit "$rc"
