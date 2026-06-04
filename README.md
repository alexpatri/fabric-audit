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

### Limpeza

```bash
./scripts/teardown.sh   # remove containers, volumes e material criptográfico gerado
```

## Mapa de portas (Fase 1)

| Componente | Serviço | Admin |
|---|---|---|
| Hospital  | CA 7054 / Orderer 7050  | 7053 |
| Governo   | CA 8054 / Orderer 8050  | 8053 |
| Auditoria | CA 9054 / Orderer 9050  | 9053 |
| Notarial  | CA 10054 / Orderer 10050 | 10053 |

## Próximas fases

2. Peers + CouchDB e criação do canal `audit-channel` (inclui `configtx.yaml` + `ConsenterMapping`).
3. Chaincode mínimo (`RegisterLog`/`QueryLog`).
4. Validações completas + índices CouchDB.
5. Cliente de submissão (Fabric Gateway SDK + inotify).
6. Testes de integridade. 7. Benchmarks (Caliper).
