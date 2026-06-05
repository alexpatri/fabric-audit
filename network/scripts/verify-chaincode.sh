#!/usr/bin/env bash
# verify-chaincode.sh — critério de aceitação da Fase 3 (SPECS §11.3):
# registra (RegisterLog, endosso AND das 3 orgs) e consulta (QueryLog) um log via CLI.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

ORD=(-o "$ORDERER_ENDPOINT" --ordererTLSHostnameOverride "$ORDERER_OVERRIDE" --tls --cafile "$(orderer_ca)")
read -ra CONN <<< "$(peer_conn_args)"
set_peer_globals hospital   # submitter = Admin@hospital (SubmitterMSP=HospitalMSP)

ACTION="act-$(date +%s)"   # único (regra 1 de unicidade) — seguro p/ reexecução
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HASH="$(printf 'conteudo-exemplo' | sha256sum | cut -d' ' -f1)"
ACTOR="alice@hospital"     # convenção user@orgkey casando com o submitter (HospitalMSP) — regra 3

echo "== RegisterLog ($ACTION) — coletando endosso das 3 orgs =="
# Sucesso = código de saída 0 (com --waitForEvent o CLI só retorna 0 após commit VALID).
# --waitForEventTimeout amplo: na 1ª invocação os peers constroem/sobem os containers de chaincode.
if peer chaincode invoke "${ORD[@]}" -C "$CHANNEL" -n "$CC_NAME" "${CONN[@]}" --waitForEvent --waitForEventTimeout 150s \
     -c "{\"function\":\"RegisterLog\",\"Args\":[\"$ACTION\",\"$TS\",\"CREATE\",\"/records/patient-42\",\"$ACTOR\",\"$HASH\",\"\",\"sess-1\",\"host-1\"]}" >/tmp/audit-invoke.log 2>&1; then
  echo "   -> RegisterLog OK (committed VALID nos 3 peers)"
else
  echo "   -> RegisterLog FALHOU:" >&2; tail -5 /tmp/audit-invoke.log >&2; exit 1
fi

echo "== QueryLog ($ACTION) =="
OUT="$(peer chaincode query -C "$CHANNEL" -n "$CC_NAME" \
        -c "{\"function\":\"QueryLog\",\"Args\":[\"$ACTION\"]}" 2>/dev/null)"
echo "$OUT" | sed 's/^/   /'

if echo "$OUT" | grep -q "\"actionId\":\"$ACTION\"" && echo "$OUT" | grep -q '"submitterMSP":"HospitalMSP"'; then
  echo ">> CRITÉRIO FASE 3 ATENDIDO: log registrado e consultado com sucesso."
else
  echo ">> CRITÉRIO FASE 3 NÃO ATENDIDO." >&2; exit 1
fi
