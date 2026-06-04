#!/usr/bin/env bash
# run-benchmark.sh — orquestra o benchmark Caliper (Fase 7).
# Copia a identidade, sobe Prometheus/Pushgateway, faz bind+launch e extrai os percentis.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../network/scripts" && pwd)/env.sh"
CAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$CAL_DIR"
mkdir -p crypto results

echo ">> copiando material da identidade auditor-agent@hospital"
UDIR="$ORG_DIR/peerOrganizations/hospital.example.com/users/auditor-agent@hospital.example.com/msp"
cp "$UDIR"/signcerts/*.pem crypto/signcert.pem
cp "$(ls "$UDIR"/keystore/* | head -1)" crypto/key.pem
cp "$(peer_tls_ca hospital)" crypto/tlsca.pem

echo ">> subindo Prometheus + Pushgateway (rede fabric_audit)"
docker compose -f monitor/docker-compose.monitor.yaml up -d
for _ in $(seq 1 30); do curl -sf http://localhost:9090/-/ready >/dev/null 2>&1 && break; sleep 1; done

if [ ! -d node_modules/@hyperledger/caliper-cli ]; then
  echo ">> npm install (caliper-cli 0.7.1)"; npm install
fi
if [ ! -f .caliper-bound ]; then
  echo ">> caliper bind fabric:fabric-gateway"
  npx caliper bind --caliper-bind-sut fabric:fabric-gateway && touch .caliper-bound
fi

launch() { # $1=benchconfig $2=report
  npx caliper launch manager --caliper-workspace . \
    --caliper-networkconfig network-config.yaml \
    --caliper-benchconfig "$1" \
    --caliper-flow-only-test \
    --caliper-report-path "$2" || echo "   (launch $1 retornou código != 0; relatório ainda gerado)"
}

echo ">> benchmark principal (write/sweep/read/mixed) — alguns minutos"
launch benchmark-config.yaml results/report-main.html

echo ">> cenário de degradação (queda de orderer.notarial durante a escrita)"
(
  sleep 30
  echo "   [deg] parando orderer.notarial"; ( cd "$NETWORK_DIR" && docker compose stop orderer.notarial.example.com >/dev/null 2>&1 )
  sleep 35
  echo "   [deg] religando orderer.notarial"; ( cd "$NETWORK_DIR" && docker compose up -d orderer.notarial.example.com >/dev/null 2>&1 )
) &
DEG_PID=$!
launch benchmark-degradation.yaml results/report-degradation.html
wait "$DEG_PID" 2>/dev/null
( cd "$NETWORK_DIR" && docker compose up -d orderer.notarial.example.com >/dev/null 2>&1 )  # garante orderer no ar

echo ">> extraindo percentis (p50/p95/p99) do Prometheus"
sleep 8  # deixa o último push ser raspado
bash extract-percentiles.sh | tee results/percentiles.md

echo
echo ">> Relatórios gerados em $CAL_DIR/results/:"
echo "   - report-main.html / report-degradation.html (Caliper: send rate, throughput, min/méd/máx, falhas)"
echo "   - percentiles.md (p50/p95/p99 por round)"
echo ">> (monitor segue no ar; pare com: docker compose -f monitor/docker-compose.monitor.yaml down)"
