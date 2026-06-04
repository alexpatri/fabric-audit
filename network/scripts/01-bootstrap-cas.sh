#!/usr/bin/env bash
# 01-bootstrap-cas.sh — sobe as 4 Fabric CAs e aguarda o material TLS de cada uma.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

cd "$NETWORK_DIR"

echo ">> Subindo as 4 Fabric CAs..."
docker compose up -d \
  ca.hospital.example.com \
  ca.governo.example.com \
  ca.auditoria.example.com \
  ca.notarial.example.com

echo ">> Aguardando geração do TLS (tls-cert.pem) de cada CA..."
for org in "${ORGS[@]}"; do
  f="$(ca_tlscert "$org")"
  ok=""
  for _ in $(seq 1 30); do
    if [ -s "$f" ]; then ok=1; break; fi
    sleep 1
  done
  if [ -z "$ok" ]; then
    echo "ERRO: $f não foi gerado pela CA de '$org'. Veja 'docker compose logs ca.$org.$DOMAIN_SUFFIX'." >&2
    exit 1
  fi
  echo "   ok: ca-$org -> $f"
done

echo ">> 4 CAs no ar."
