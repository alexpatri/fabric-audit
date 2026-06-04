#!/usr/bin/env bash
# 02-enroll-identities.sh — enrola, via ./bin/fabric-ca-client, as identidades
# necessárias à Fase 1: o registrar (admin) de cada CA e o ordenador de cada org
# (MSP padrão + certificados TLS pelo perfil 'tls').
#
# Identidades de peer0/org-admin/auditor-agent (SPECS §7.1) são enroladas nas
# fases em que passam a ser usadas (Fases 2/5), não aqui.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

write_nodeou_config() {
  # $1 = diretório MSP. Habilita NodeOUs apontando para o CA cert em cacerts/.
  local msp="$1"
  local cacert
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

enroll_org() {
  local org="$1"
  local caname caport tlscert ordhost ordmsp ordtls registrar_home
  caname="$(ca_name "$org")"
  caport="${CA_PORT[$org]}"
  tlscert="$(ca_tlscert "$org")"
  ordhost="$(ord_host "$org")"
  ordmsp="$(ord_msp "$org")"
  ordtls="$(ord_tls "$org")"
  registrar_home="$(ord_base "$org")/ca-registrar"

  echo ">> [$org] enroll do registrar (admin) da CA"
  export FABRIC_CA_CLIENT_HOME="$registrar_home"
  fabric-ca-client enroll \
    -u "https://admin:adminpw@localhost:$caport" \
    --caname "$caname" --tls.certfiles "$tlscert"

  echo ">> [$org] registro da identidade do ordenador"
  fabric-ca-client register \
    --caname "$caname" --tls.certfiles "$tlscert" \
    --id.name "orderer-$org" --id.secret ordererpw --id.type orderer \
    2>&1 | grep -v "is already registered" || true

  echo ">> [$org] enroll do MSP do ordenador"
  rm -rf "$ordmsp"
  fabric-ca-client enroll \
    -u "https://orderer-$org:ordererpw@localhost:$caport" \
    --caname "$caname" --tls.certfiles "$tlscert" \
    -M "$ordmsp"
  write_nodeou_config "$ordmsp"

  echo ">> [$org] enroll TLS do ordenador (perfil 'tls')"
  rm -rf "$ordtls"
  fabric-ca-client enroll \
    -u "https://orderer-$org:ordererpw@localhost:$caport" \
    --caname "$caname" --tls.certfiles "$tlscert" \
    --enrollment.profile tls \
    --csr.hosts "$ordhost,localhost,127.0.0.1" \
    -M "$ordtls"

  # Normaliza nomes esperados pelo orderer.
  cp "$(ls "$ordtls"/tlscacerts/*.pem | head -n1)" "$ordtls/ca.crt"
  cp "$(ls "$ordtls"/signcerts/*.pem | head -n1)"  "$ordtls/server.crt"
  cp "$(ls "$ordtls"/keystore/*       | head -n1)" "$ordtls/server.key"

  echo "   ok: $org (MSP + TLS prontos)"
}

for org in "${ORGS[@]}"; do
  enroll_org "$org"
done

echo ">> Enrollment concluído para os 4 ordenadores."
