#!/usr/bin/env bash
# teardown.sh — derruba todos os containers/volumes e limpa o material criptográfico
# gerado em runtime, deixando o repositório pronto para um bootstrap limpo (SPECS §12).
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

cd "$NETWORK_DIR"

echo ">> Derrubando containers e volumes nomeados..."
docker compose down -v --remove-orphans || true

echo ">> Limpando material criptográfico gerado (fabric-ca/* e ordererOrganizations/*)..."
# Arquivos da CA são criados como root no container; removemos via container para não exigir sudo.
docker run --rm -v "$ORG_DIR":/org alpine:3 \
  sh -c 'rm -rf /org/fabric-ca/*/* /org/ordererOrganizations/* 2>/dev/null; true'

echo ">> Teardown concluído."
