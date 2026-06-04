#!/usr/bin/env bash
# 02-enroll-identities.sh — enrola, via ./bin/fabric-ca-client, as identidades da rede:
#   Fase 1: registrar (admin) de cada CA + ordenador de cada org (MSP padrão + TLS).
#   Fase 2: peer0 + Admin das 3 orgs de aplicação (MSP/TLS) + MSP nível-org das 4 orgs.
# Idempotente: enrollments que já produziram material são pulados (não regenera chaves).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

# Habilita NodeOUs em um MSP apontando para o (único) CA cert em cacerts/.
write_nodeou_config() {
  local msp="$1" cacert
  cacert="$(basename "$(ls "$msp"/cacerts/*.pem | head -n1)")"
  cat > "$msp/config.yaml" <<EOF
NodeOUs:
  Enable: true
  ClientOUIdentifier:
    Certificate: cacerts/$cacert
    OrganizationalUnitIdentifier: client
  PeerOUIdentifier:
    Certificate: cacerts/$cacert
    OrganizationalUnitIdentifier: peer
  AdminOUIdentifier:
    Certificate: cacerts/$cacert
    OrganizationalUnitIdentifier: admin
  OrdererOUIdentifier:
    Certificate: cacerts/$cacert
    OrganizationalUnitIdentifier: orderer
EOF
}

# Normaliza saída do enroll TLS para os nomes esperados (ca.crt/server.crt/server.key).
normalize_tls() {
  local tls="$1"
  cp "$(ls "$tls"/tlscacerts/*.pem | head -n1)" "$tls/ca.crt"
  cp "$(ls "$tls"/signcerts/*.pem  | head -n1)" "$tls/server.crt"
  cp "$(ls "$tls"/keystore/*        | head -n1)" "$tls/server.key"
}

registrar_home() { echo "$(ord_base "$1")/ca-registrar"; }

# Garante que o registrar (admin) da CA esteja enrolado (idempotente).
ensure_registrar() {
  local org="$1" home; home="$(registrar_home "$org")"
  if [ -f "$home/msp/signcerts/cert.pem" ]; then return; fi
  echo ">> [$org] enroll do registrar (admin) da CA"
  FABRIC_CA_CLIENT_HOME="$home" fabric-ca-client enroll \
    -u "https://admin:adminpw@localhost:${CA_PORT[$org]}" \
    --caname "$(ca_name "$org")" --tls.certfiles "$(ca_tlscert "$org")"
}

# Registra uma identidade (ignora se já registrada).
register_id() {
  local org="$1" name="$2" secret="$3" type="$4"
  FABRIC_CA_CLIENT_HOME="$(registrar_home "$org")" fabric-ca-client register \
    --caname "$(ca_name "$org")" --tls.certfiles "$(ca_tlscert "$org")" \
    --id.name "$name" --id.secret "$secret" --id.type "$type" \
    2>&1 | grep -v "is already registered" || true
}

# Enroll de MSP (padrão) para uma identidade, em $dest_msp.
enroll_msp() {
  local org="$1" name="$2" secret="$3" dest="$4"
  [ -f "$dest/signcerts/cert.pem" ] && return
  fabric-ca-client enroll \
    -u "https://$name:$secret@localhost:${CA_PORT[$org]}" \
    --caname "$(ca_name "$org")" --tls.certfiles "$(ca_tlscert "$org")" -M "$dest"
  write_nodeou_config "$dest"
}

# Enroll de TLS (perfil 'tls') para uma identidade, em $dest_tls.
enroll_tls() {
  local org="$1" name="$2" secret="$3" dest="$4" host="$5"
  [ -f "$dest/server.crt" ] && return
  fabric-ca-client enroll \
    -u "https://$name:$secret@localhost:${CA_PORT[$org]}" \
    --caname "$(ca_name "$org")" --tls.certfiles "$(ca_tlscert "$org")" \
    --enrollment.profile tls --csr.hosts "$host,localhost,127.0.0.1" -M "$dest"
  normalize_tls "$dest"
}

# Monta o MSP nível-org (cacerts + tlscacerts = ca-cert.pem da org + config.yaml NodeOUs).
build_org_msp() {
  local org="$1" dest="$2"
  mkdir -p "$dest/cacerts" "$dest/tlscacerts"
  cp "$(ca_cert "$org")" "$dest/cacerts/ca-cert.pem"
  cp "$(ca_cert "$org")" "$dest/tlscacerts/ca-cert.pem"
  write_nodeou_config "$dest"
}

# ===================== Ordenadores (4 orgs) =====================
for org in "${ORGS[@]}"; do
  ensure_registrar "$org"
  register_id "$org" "orderer-$org" ordererpw orderer
  enroll_msp "$org" "orderer-$org" ordererpw "$(ord_msp "$org")"
  enroll_tls "$org" "orderer-$org" ordererpw "$(ord_tls "$org")" "$(ord_host "$org")"
  echo "   ok orderer: $org"
done

# ============ Peers + Admins (3 orgs de aplicação) =============
for org in "${APP_ORGS[@]}"; do
  ensure_registrar "$org"
  register_id "$org" "peer0-$org"  peer0pw  peer
  register_id "$org" "${org}admin" adminpw  admin
  enroll_msp "$org" "peer0-$org"  peer0pw  "$(peer_node_msp "$org")"
  enroll_tls "$org" "peer0-$org"  peer0pw  "$(peer_node_tls "$org")" "$(peer_host "$org")"
  enroll_msp "$org" "${org}admin" adminpw  "$(admin_msp "$org")"
  echo "   ok peer+admin: $org"
done

# =================== MSPs nível-organização ====================
# Orgs de aplicação: usadas nos grupos Orderer e Application -> peerOrganizations/<org>/msp
for org in "${APP_ORGS[@]}"; do build_org_msp "$org" "$(peer_org_msp "$org")"; done
# Notarial: só ordena -> ordererOrganizations/notarial/msp
build_org_msp notarial "$(ord_org_msp notarial)"
echo ">> Org-level MSPs montados."

echo ">> Enrollment concluído (ordenadores + peers + admins + org-MSPs)."
