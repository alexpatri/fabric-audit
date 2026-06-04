# fabric-audit — Rede Hyperledger Fabric para Auditoria Descentralizada

Infraestrutura de rede blockchain permissionada (Hyperledger Fabric **v3.1.4**, ordenação
**BFT/SmartBFT**) para registro forense de eventos de auditoria.

## Estado atual: Fase 1 — Bootstrap da rede mínima (SPECS §11.1)

Sobe **4 Fabric CAs** (v1.5.19) e **4 ordenadores BFT** (v3.1.4), um por organização
(Hospital, Governo, Auditoria, Notarial). Nesta fase **não há canal**: os ordenadores iniciam
"nus" via *channel participation API*.

**Critério de aceitação:** `osnadmin channel list` responde nos 4 ordenadores.

## Pré-requisitos

- Docker Engine 24+ / Docker Compose v2
- Imagens: `hyperledger/fabric-orderer:3.1.4`, `hyperledger/fabric-ca:1.5.19`
- Binários oficiais em `./bin/` (Fabric v3.1.4 + fabric-ca 1.5.19): `osnadmin`,
  `configtxgen`, `peer`, `fabric-ca-client`. (Não publicados como imagem `fabric-tools` na v3.x.)

## Execução

```bash
cd network

# 1) Sobe as 4 Fabric CAs e aguarda o material TLS
./scripts/01-bootstrap-cas.sh

# 2) Enrola MSP + TLS dos 4 ordenadores
./scripts/02-enroll-identities.sh

# 3) Sobe os 4 ordenadores BFT (sem canal)
docker compose up -d \
  orderer.hospital.example.com orderer.governo.example.com \
  orderer.auditoria.example.com orderer.notarial.example.com

# 4) Verifica o critério de aceitação da Fase 1
./scripts/verify-orderers.sh
```

Saída esperada por ordenador: `{"systemChannel":null,"channels":[]}` (HTTP 200).

## Fase 2 — Peers e canal `audit-channel` (SPECS §11.2)

Sobe os 3 peers + CouchDBs, cria o canal `audit-channel` (BFT, capability `V3_0`) e faz os
peers ingressarem. **Critério:** `peer channel list` mostra `audit-channel` em cada peer.

```bash
cd network

# (pré) imagem do CouchDB
docker pull couchdb:3.4.2

# 2) Enrola também peer0 + Admin das 3 app orgs e monta os MSPs de organização
#    (idempotente: não regenera as identidades dos orderers da Fase 1)
./scripts/02-enroll-identities.sh

# 3) Cria o canal e faz os peers ingressarem
#    (recria orderers c/ cluster BFT, gera gênese, osnadmin join, sobe peers/couchdb, peer join)
./scripts/03-create-channel.sh

# 4) Verifica o critério da Fase 2
./scripts/verify-channel.sh
```

## Fase 3 — Chaincode mínimo (SPECS §11.3)

Implementa o chaincode Go `audit-chaincode` (lifecycle v2.x) com `RegisterLog` e `QueryLog`,
instala/aprova/commita com a política `AND('HospitalMSP.peer','GovernoMSP.peer','AuditoriaMSP.peer')`.
**Critério:** invocação manual via CLI registra e consulta um log.

```bash
cd network

# (pré) os 3 peers precisam de acesso ao Docker (builder tradicional) — recria-os
docker compose up -d \
  peer0.hospital.example.com peer0.governo.example.com peer0.auditoria.example.com

# 4) Empacota, instala, aprova (3 orgs) e commita
./scripts/04-deploy-chaincode.sh

# 5) Verifica o critério da Fase 3
./scripts/verify-chaincode.sh
```

### Limpeza

```bash
./scripts/teardown.sh   # remove containers, volumes, material criptográfico e chaincode dev-*
```

## Mapa de portas (Fase 1)

| Componente | Serviço | Admin |
|---|---|---|
| Hospital  | CA 7054 / Orderer 7050  | 7053 |
| Governo   | CA 8054 / Orderer 8050  | 8053 |
| Auditoria | CA 9054 / Orderer 9050  | 9053 |
| Notarial  | CA 10054 / Orderer 10050 | 10053 |

## Próximas fases

4. Validações completas + índices CouchDB.
5. Cliente de submissão (Fabric Gateway SDK + inotify).
6. Testes de integridade. 7. Benchmarks (Caliper).
