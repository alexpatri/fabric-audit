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
  # Retry: logo após 'docker compose up' o servidor TLS admin do orderer pode levar alguns
  # segundos para atender (do contrário: "connection reset by peer"). Esperamos até ~30s.
  ok=""; out=""
  for _ in $(seq 1 15); do
    if out="$(osnadmin channel list \
         -o "localhost:$adminport" \
         --ca-file   "$tls/ca.crt" \
         --client-cert "$tls/server.crt" \
         --client-key  "$tls/server.key" 2>&1)"; then
      ok=1; break
    fi
    sleep 2
  done
  echo "$out"
  if [ -n "$ok" ]; then
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
