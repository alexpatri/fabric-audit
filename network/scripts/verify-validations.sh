#!/usr/bin/env bash
# verify-validations.sh — demonstração de integração da Fase 4: encadeamento de hash,
# as 4 queries novas e as rejeições das regras §6.6. (Critério formal = cobertura unitária ≥80%.)
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

ORD=(-o "$ORDERER_ENDPOINT" --ordererTLSHostnameOverride "$ORDERER_OVERRIDE" --tls --cafile "$(orderer_ca)")
read -ra CONN <<< "$(peer_conn_args)"
set_peer_globals hospital

RUN="$(date +%s)"
RES="/records/patient-$RUN"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
H1="$(printf 'v1-%s' "$RUN" | sha256sum | cut -d' ' -f1)"
H2="$(printf 'v2-%s' "$RUN" | sha256sum | cut -d' ' -f1)"
rc=0

cc_invoke() { # $1 = JSON; retorna exit code do invoke (0 = committed VALID)
  peer chaincode invoke "${ORD[@]}" -C "$CHANNEL" -n "$CC_NAME" "${CONN[@]}" \
    --waitForEvent --waitForEventTimeout 120s -c "$1" >/tmp/audit-v.log 2>&1
}
cc_query() { peer chaincode query -C "$CHANNEL" -n "$CC_NAME" -c "$1" 2>/dev/null; }
reglog() { # build RegisterLog args: action ts op res actor content prev
  printf '{"function":"RegisterLog","Args":["%s","%s","%s","%s","%s","%s","%s","sess","host"]}' "$@"
}
ok()   { echo "   PASS: $1"; }
bad()  { echo "   FALHA: $1" >&2; rc=1; }
expect_ok()   { if cc_invoke "$1"; then ok "$2"; else bad "$2 (esperava OK)"; tail -3 /tmp/audit-v.log >&2; fi; }
expect_fail() { if cc_invoke "$1"; then bad "$2 (esperava rejeição)"; else ok "$2 (rejeitado)"; fi; }

echo "== Caminho feliz: CREATE -> UPDATE (encadeamento de hash) =="
expect_ok   "$(reglog "c-$RUN" "$TS" CREATE "$RES" "alice@hospital" "$H1" "")"          "CREATE"
expect_ok   "$(reglog "u-$RUN" "$TS" UPDATE "$RES" "alice@hospital" "$H2" "$H1")"        "UPDATE (prev==último hash)"

echo "== Queries =="
cc_query "{\"function\":\"QueryLog\",\"Args\":[\"c-$RUN\"]}" | grep -q "\"actionId\":\"c-$RUN\"" \
  && ok "QueryLog" || bad "QueryLog"
LAST="$(cc_query "{\"function\":\"GetLastHashForResource\",\"Args\":[\"$RES\"]}")"
[ "$LAST" = "$H2" ] && ok "GetLastHashForResource (= H2 do UPDATE)" || bad "GetLastHashForResource (got '$LAST')"
cc_query "{\"function\":\"QueryLogsByResource\",\"Args\":[\"$RES\"]}" | grep -q "u-$RUN" \
  && ok "QueryLogsByResource" || bad "QueryLogsByResource"
cc_query "{\"function\":\"QueryLogsByActor\",\"Args\":[\"alice@hospital\"]}" | grep -q "c-$RUN" \
  && ok "QueryLogsByActor" || bad "QueryLogsByActor"
cc_query "{\"function\":\"QueryLogsByTimeRange\",\"Args\":[\"2000-01-01T00:00:00Z\",\"2100-01-01T00:00:00Z\"]}" | grep -q "c-$RUN" \
  && ok "QueryLogsByTimeRange" || bad "QueryLogsByTimeRange"

echo "== Rejeições §6.6 =="
FUT="$(date -u -d '+10 min' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v+10M +%Y-%m-%dT%H:%M:%SZ)"
expect_fail "$(reglog "x1-$RUN" "$TS" PURGE  "$RES" "alice@hospital" "$H1" "")"          "operação inválida (regra 5)"
expect_fail "$(reglog "x2-$RUN" "$FUT" CREATE "$RES" "alice@hospital" "$H1" "")"          "timestamp futuro (regra 4)"
expect_fail "$(reglog "c-$RUN" "$TS" CREATE "$RES" "alice@hospital" "$H1" "")"            "actionId duplicado (regra 1)"
expect_fail "$(reglog "x3-$RUN" "$TS" UPDATE "$RES" "alice@hospital" "$H2" "deadbeef")"   "prev-hash mal-formado (regra 6)"
expect_fail "$(reglog "x4-$RUN" "$TS" CREATE "$RES" "bob@governo"    "$H1" "")"           "ator de outra org (regra 3)"

if [ "$rc" -eq 0 ]; then
  echo ">> FASE 4 (integração) OK: validações §6.6 e queries §6.4 funcionando."
else
  echo ">> FASE 4 (integração): houve falhas." >&2
fi
exit "$rc"
