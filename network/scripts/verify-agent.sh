#!/usr/bin/env bash
# verify-agent.sh — critério de aceitação da Fase 5 (SPECS §11.5):
# subir o agente, criar um arquivo no diretório monitorado e confirmar a transação commitada.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

export FABRIC_AUDIT_ROOT="$ROOT_DIR"
WATCH_DIR="$(mktemp -d)"; export WATCH_DIR
AGENT_BIN="$ROOT_DIR/client/bin/agent"
LOG="$(mktemp)"

cleanup() { [ -n "${AGENT_PID:-}" ] && kill "$AGENT_PID" 2>/dev/null; rm -rf "$WATCH_DIR" "$LOG"; }
trap cleanup EXIT

echo ">> build do agente"
( cd "$ROOT_DIR/client" && go build -o "$AGENT_BIN" ./cmd/agent ) || { echo "build falhou" >&2; exit 1; }

echo ">> subindo o agente (monitorando $WATCH_DIR)"
"$AGENT_BIN" -config "$ROOT_DIR/client/config/agent.yaml" >"$LOG" 2>&1 &
AGENT_PID=$!
for _ in $(seq 1 40); do grep -q "monitorando diretório" "$LOG" && break; sleep 0.5; done
if ! grep -q "monitorando diretório" "$LOG"; then echo "agente não iniciou:" >&2; cat "$LOG" >&2; exit 1; fi

FILE="$WATCH_DIR/evento-$(date +%s).txt"
echo "conteudo de auditoria $(date)" > "$FILE"
echo ">> arquivo criado: $FILE"

ok=""
for _ in $(seq 1 90); do
  grep -q "committed .*resource=$FILE" "$LOG" && { ok=1; break; }
  grep -q "FALHA .*resource=$FILE" "$LOG" && break
  sleep 1
done
echo "=== log do agente ==="; grep -E "agente iniciado|monitorando|committed|tentativa|FALHA" "$LOG" | sed 's/^/   /'
[ -n "$ok" ] || { echo ">> FALHA: agente não reportou commit." >&2; exit 1; }

echo ">> consultando o ledger: QueryLogsByResource($FILE)"
set_peer_globals hospital
OUT="$(peer chaincode query -C "$CHANNEL" -n "$CC_NAME" -c "{\"function\":\"QueryLogsByResource\",\"Args\":[\"$FILE\"]}" 2>/dev/null)"
echo "$OUT" | sed 's/^/   /'

if echo "$OUT" | grep -q "\"resource\":\"$FILE\""; then
  echo ">> CRITÉRIO FASE 5 ATENDIDO: criar um arquivo gerou transação commitada no ledger."
else
  echo ">> CRITÉRIO FASE 5 NÃO ATENDIDO." >&2; exit 1
fi
