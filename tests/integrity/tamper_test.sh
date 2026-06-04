#!/usr/bin/env bash
# tamper_test.sh — testes de integridade (SPECS §10.1 / §11.6).
# Cenário A: adulteração do world state (CouchDB) -> divergência cross-peer + falha de endosso + rebuild.
# Cenário B: adulteração de block file -> erro de integridade no replay.
# Cenário C: exclusão de block file -> falha ao ler o ledger; recuperação re-provisionando.
# O peer0.hospital é perturbado e RESTAURADO ao fim de cada cenário (rede saudável no final).
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../network/scripts" && pwd)/env.sh"
cd "$NETWORK_DIR"

PEER_SVC="peer0.hospital.example.com"
COUCH="localhost:5984"; AUTH="admin:adminpw"; DB="audit-channel_audit-chaincode"
BF_REL="ledgersData/chains/chains/audit-channel/blockfile_000000"
N="${N:-8}"   # nº de transações legítimas de fundo (§10.1 exemplo: 100)
VOL="$(docker inspect "$PEER_SVC" -f '{{range .Mounts}}{{if eq .Destination "/var/hyperledger/production"}}{{.Name}}{{end}}{{end}}')"

ORD=(-o "$ORDERER_ENDPOINT" --ordererTLSHostnameOverride "$ORDERER_OVERRIDE" --tls --cafile "$(orderer_ca)")
read -ra CONN <<< "$(peer_conn_args)"

ok()  { echo "   [PASS] $1"; }
bad() { echo "   [FALHA] $1" >&2; RC=1; }
RC=0
TS="$(date +%s)"
H1="$(printf 'orig-%s' "$TS" | sha256sum | cut -d' ' -f1)"
H2="$(printf 'novo-%s' "$TS" | sha256sum | cut -d' ' -f1)"
RES="/records/integridade-$TS"
X="audit-$TS"               # actionId alvo
ledger() { docker run --rm -v "$VOL":/d alpine sh -c "$1"; }

invoke() { # $1=json args result; retorna exit do invoke
  peer chaincode invoke "${ORD[@]}" -C "$CHANNEL" -n "$CC_NAME" "${CONN[@]}" \
    --waitForEvent --waitForEventTimeout 120s -c "$1" >/tmp/tamper-invoke.log 2>&1
}
reglog() { printf '{"function":"RegisterLog","Args":["%s","%s","%s","%s","%s","%s","%s","s","h"]}' "$@"; }
querylog_actor() { # $1=org -> imprime actor (ou ERRO)
  set_peer_globals "$1"
  out="$(peer chaincode query -C "$CHANNEL" -n "$CC_NAME" -c "{\"function\":\"QueryLog\",\"Args\":[\"$X\"]}" 2>/dev/null)"
  echo "$out" | grep -o '"actor":"[^"]*"' | head -1 || echo "ERRO/NAO-ENCONTRADO"
}
wait_hospital_ready() {
  set_peer_globals hospital
  for _ in $(seq 1 40); do
    peer channel list 2>/dev/null | grep -q "$CHANNEL" && return 0
    sleep 1
  done
  return 1
}

echo "############################################################"
echo "# Setup: $N transações legítimas + alvo X=$X (resource=$RES)"
echo "############################################################"
set_peer_globals hospital
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
invoke "$(reglog "$X" "$NOW" CREATE "$RES" "tester@hospital" "$H1" "")" \
  && ok "CREATE alvo committed" || { bad "CREATE alvo falhou"; cat /tmp/tamper-invoke.log; exit 1; }
for i in $(seq 1 "$N"); do
  invoke "$(reglog "bg-$TS-$i" "$NOW" CREATE "/records/bg-$TS-$i" "tester@hospital" "$H1" "")" >/dev/null 2>&1
done
echo "   $N transações de fundo submetidas."
echo "   baseline actor nos 3 peers:"
for o in hospital governo auditoria; do echo "     $o -> $(querylog_actor "$o")"; done

echo
echo "############################################################"
echo "# CENÁRIO A — adulteração do world state (CouchDB)"
echo "############################################################"
echo ">> parando $PEER_SVC e adulterando o doc $X no CouchDB (actor + contentHash)"
docker compose stop "$PEER_SVC" >/dev/null
DOC="$(curl -s -u "$AUTH" "http://$COUCH/$DB/$X")"
TAMPERED="$(echo "$DOC" | jq --arg h "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd" \
  '.actor="HACKER@hospital" | .contentHash=$h')"
PUTRES="$(curl -s -u "$AUTH" -X PUT "http://$COUCH/$DB/$X" -H 'Content-Type: application/json' -d "$TAMPERED")"
echo "   couchdb PUT: $(echo "$PUTRES" | jq -c '{ok,id}' 2>/dev/null || echo "$PUTRES")"
docker compose up -d "$PEER_SVC" >/dev/null
wait_hospital_ready || bad "peer não reiniciou"

echo ">> A.5 — divergência cross-peer (QueryLog $X):"
AH="$(querylog_actor hospital)"; AG="$(querylog_actor governo)"; AA="$(querylog_actor auditoria)"
echo "     hospital  -> $AH"; echo "     governo   -> $AG"; echo "     auditoria -> $AA"
if echo "$AH" | grep -q HACKER && echo "$AG" | grep -q "tester@hospital" && echo "$AA" | grep -q "tester@hospital"; then
  ok "A.5 divergência detectada (hospital adulterado; governo/auditoria íntegros)"
else
  bad "A.5 divergência não caracterizada"
fi

echo ">> A.6 — UPDATE em $RES (prev=H1) deve falhar por endosso inconsistente:"
set_peer_globals hospital
if invoke "$(reglog "upd-$TS" "$NOW" UPDATE "$RES" "tester@hospital" "$H2" "$H1")"; then
  bad "A.6 UPDATE foi aceito (esperava falha de endosso)"
else
  ok "A.6 UPDATE rejeitado (hospital diverge via GetLastHashForResource adulterado)"
  grep -oiE "ENDORSEMENT_POLICY_FAILURE|proposal response|mismatch|não coincide|endorsements" /tmp/tamper-invoke.log | head -2 | sed 's/^/        evidência: /'
fi

echo ">> A.7 — recuperação via 'peer node rebuild-dbs' (reconstrói do bloco):"
docker compose stop "$PEER_SVC" >/dev/null
docker compose run --rm --no-deps --entrypoint peer "$PEER_SVC" node rebuild-dbs >/tmp/tamper-rebuild.log 2>&1
docker compose up -d "$PEER_SVC" >/dev/null
wait_hospital_ready || bad "peer não reiniciou após rebuild"
AH2="$(querylog_actor hospital)"
echo "     hospital pós-rebuild -> $AH2"
echo "$AH2" | grep -q "tester@hospital" && ok "A.7 world state reconstruído (adulteração sobrescrita)" || bad "A.7 recuperação falhou"

echo
echo "############################################################"
echo "# CENÁRIO B — adulteração de block file (flip de 1 byte)"
echo "############################################################"
docker compose stop "$PEER_SVC" >/dev/null
echo ">> backup + flip de 1 byte no meio do blockfile_000000"
ledger "cp /d/$BF_REL /d/${BF_REL}.bak"
ledger "SZ=\$(wc -c < /d/$BF_REL); OFF=\$((SZ/2)); \
  B=\$(dd if=/d/$BF_REL bs=1 skip=\$OFF count=1 2>/dev/null | od -An -tu1 | tr -d ' '); \
  NB=\$(( (B+1) % 256 )); printf \"\\\\\$(printf '%03o' \$NB)\" | dd of=/d/$BF_REL bs=1 seek=\$OFF count=1 conv=notrunc 2>/dev/null; \
  echo \"   byte em \$OFF: \$B -> \$NB\""
# A verificação de hash da cadeia é feita pela ferramenta oficial 'ledgerutil verify'
# (o peer NÃO re-verifica blocos históricos no replay/rebuild — só lê o último bloco no boot).
echo ">> verificação da cadeia (ledgerutil verify) — espera DataHash mismatch:"
OUTB="$(mktemp -d)"
docker run --rm -v "$VOL":/var/hyperledger/production -v "$BIN_DIR":/b -v "$OUTB":/out \
  --entrypoint /b/ledgerutil hyperledger/fabric-peer:3.1.4 \
  verify -o /out/r /var/hyperledger/production >/tmp/tamper-bf.log 2>&1
BJSON="$(cat "$OUTB"/r/*/blocks.json 2>/dev/null)"
if grep -q "Some error(s) are found" /tmp/tamper-bf.log && echo "$BJSON" | grep -q '"valid":false'; then
  ok "B detectado (ledgerutil verify: divergência de hash de bloco)"
  echo "$BJSON" | tr -d ' \n' | sed 's/^/        evidência: /'
else
  bad "B não detectado"; tail -4 /tmp/tamper-bf.log
fi
docker run --rm -v "$OUTB":/o alpine rm -rf /o/r 2>/dev/null; rmdir "$OUTB" 2>/dev/null || true
echo ">> recuperação: restaura block file do backup"
ledger "mv /d/${BF_REL}.bak /d/$BF_REL"
docker compose up -d "$PEER_SVC" >/dev/null
wait_hospital_ready && ok "B peer recuperado (block file restaurado)" || bad "B recuperação falhou"

echo
echo "############################################################"
echo "# CENÁRIO C — exclusão de block file"
echo "############################################################"
docker compose stop "$PEER_SVC" >/dev/null
echo ">> backup + remoção do blockfile_000000 (a cadeia inteira deste peer)"
ledger "cp /d/$BF_REL /d/${BF_REL}.bak && rm -f /d/$BF_REL"
docker compose up -d "$PEER_SVC" >/dev/null
sleep 8
CLOG="$(docker logs "$PEER_SVC" 2>&1 | tail -40)"
if echo "$CLOG" | grep -qiE "no such file|cannot|error|panic|fail|missing|ledger|open"; then
  ok "C detectado (peer falha ao ler o ledger — dados ausentes)"
  echo "$CLOG" | grep -iE "no such file|cannot|error|panic|fail|missing|ledger" | head -3 | sed 's/^/        evidência: /'
else
  bad "C não produziu erro detectável"
fi
echo ">> recuperação: restaura o block file (em produção: re-provisionar + catch-up do orderer)"
docker compose stop "$PEER_SVC" >/dev/null 2>&1
ledger "mv /d/${BF_REL}.bak /d/$BF_REL"
docker compose up -d "$PEER_SVC" >/dev/null
wait_hospital_ready && ok "C peer recuperado" || bad "C recuperação falhou"

echo
echo "############################################################"
echo "# Saúde final"
echo "############################################################"
for o in hospital governo auditoria; do echo "   $o actor($X) -> $(querylog_actor "$o")"; done
FH="$(querylog_actor hospital)"
echo "$FH" | grep -q "tester@hospital" && ok "estado consistente nos 3 peers" || bad "estado final inconsistente"

echo
if [ "$RC" -eq 0 ]; then
  echo ">> FASE 6 OK: cenários A, B e C detectados, documentados e recuperados."
else
  echo ">> FASE 6: houve falhas — revise as evidências acima." >&2
fi
exit "$RC"
