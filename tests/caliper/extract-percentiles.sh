#!/usr/bin/env bash
# extract-percentiles.sh — calcula p50/p95/p99 de latência e2e por round, via Prometheus.
# Uso: extract-percentiles.sh [round1 round2 ...]   (default: todos os rounds conhecidos)
set -uo pipefail
PROM="${PROM:-http://localhost:9090}"
ROUNDS=("$@")
[ ${#ROUNDS[@]} -eq 0 ] && ROUNDS=(seed sweep-10 sweep-50 sweep-100 sweep-200 read mixed-80-20 degradation)

q() { # $1=quantil $2=roundLabel
  local expr="histogram_quantile($1, sum by (le) (increase(caliper_tx_e2e_latency_bucket{roundLabel=\"$2\",final_status=\"success\"}[1h])))"
  curl -sG "$PROM/api/v1/query" --data-urlencode "query=$expr" | jq -r '.data.result[0].value[1] // "n/a"'
}

printf "| round | p50 (s) | p95 (s) | p99 (s) |\n|---|---|---|---|\n"
for R in "${ROUNDS[@]}"; do
  printf "| %s | %s | %s | %s |\n" "$R" "$(q 0.50 "$R")" "$(q 0.95 "$R")" "$(q 0.99 "$R")"
done
