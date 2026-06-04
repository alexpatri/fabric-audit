# Rede Hyperledger Fabric para Auditoria Descentralizada

Infraestrutura de uma **blockchain permissionada** baseada em **Hyperledger Fabric v3.1.4** com
ordenação **bizantina (SmartBFT)** para **registro forense imutável de eventos de auditoria** em
infraestruturas críticas. O sistema garante integridade, imutabilidade e verificabilidade dos logs
mesmo sob comprometimento parcial de nós, distribuindo a confiança entre organizações com
interesses distintos via política de endosso conjunta.


---

## 1. Visão geral

- **Consenso bizantino (BFT):** o serviço de ordenação usa **SmartBFT** (disponível a partir do
  Fabric v3.0), que tolera nós maliciosos/arbitrários — não apenas falhas por crash (CFT/Raft).
  Com **4 ordenadores** (`3f+1`, `f=1`), a rede tolera **1 ordenador bizantino**.
- **Confiança distribuída:** cada transação exige endosso conjunto de **três organizações** com
  papéis distintos (operadora, regulador, auditor), via política
  `AND('HospitalMSP.peer','GovernoMSP.peer','AuditoriaMSP.peer')`.
- **Imutabilidade por design:** o chaincode **não** expõe funções de exclusão ou alteração — só
  inserção (append) e leitura. Encadeamento de hash (`contentHash`/`previousContentHash`) liga as
  versões de cada recurso.
- **Captura automática:** um agente cliente em Go observa o filesystem (inotify) e registra os
  eventos no ledger via Fabric Gateway SDK.

---

## 2. Arquitetura

### 2.1 Organizações

| Organização | MSP ID | Papel | Componentes |
|---|---|---|---|
| Hospital | `HospitalMSP` | Operadora regulada (infra auditada) | 1 peer, 1 orderer, 1 CA |
| Governo | `GovernoMSP` | Órgão regulador | 1 peer, 1 orderer, 1 CA |
| Auditoria | `AuditoriaMSP` | Auditor independente | 1 peer, 1 orderer, 1 CA |
| Notarial | `NotarialMSP` | Terceiro neutro (só ordenação) | 1 orderer, 1 CA |

A **quarta organização (Notarial)** existe para hospedar o 4º ordenador como parte imparcial:
concentrar dois ordenadores numa única org daria a ela poder de veto sobre o consenso, violando a
premissa BFT.

**MSP compartilhado por organização:** cada org de aplicação roda **peer e orderer sob o mesmo
MSP** (NodeOUs distinguem `peer`/`orderer`/`client`/`admin`). Assim `HospitalMSP/GovernoMSP/
AuditoriaMSP` aparecem nos grupos *Orderer* **e** *Application* do canal; `NotarialMSP` só no *Orderer*.

### 2.2 Topologia

```
                         Canal: audit-channel (capability V3_0)
                  ┌───────────────── Ordenação BFT (SmartBFT, 4 nós) ─────────────────┐
                  │ orderer.hospital  orderer.governo  orderer.auditoria  orderer.notarial │
                  └───────────────────────────────────────────────────────────────────┘
                          ▲                ▲                 ▲
       endosso (AND 3 orgs)│                │                 │
   ┌──────────────┐   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
   │ peer0.hospital│  │ peer0.governo │  │peer0.auditoria│  │  (sem peer)  │
   │  + CouchDB    │  │  + CouchDB    │  │  + CouchDB    │  │   Notarial   │
   └──────────────┘   └──────────────┘  └──────────────┘  └──────────────┘
        ▲ Gateway (1 conexão; endosso das 3 orgs resolvido server-side)
   ┌────┴───────────────┐
   │  agente capturador │  (Go + Fabric Gateway SDK + inotify)
   └────────────────────┘
   4 Fabric CAs (1.5.19) emitem identidades MSP e TLS (perfil 'tls') por organização.
```

### 2.3 Mapa de portas

| Componente | Serviço | Admin/Chaincode |
|---|---|---|
| ca.hospital / governo / auditoria / notarial | 7054 / 8054 / 9054 / 10054 | — |
| orderer.hospital / governo / auditoria / notarial | 7050 / 8050 / 9050 / 10050 | admin 7053 / 8053 / 9053 / 10053 |
| peer0.hospital / governo / auditoria | 7051 / 9051 / 11051 | chaincode 7052 / 9052 / 11052 |
| couchdb.hospital / governo / auditoria | 5984 / 6984 / 7984 | — |
| Prometheus / Pushgateway (benchmark) | 9090 / 9091 | — |

Domínios estilo `example.com` (`peer0.hospital.example.com`, `orderer.hospital.example.com`, …).

---

## 3. Estrutura do repositório

```
fabric-audit/
├── bin/                       # binários oficiais (gitignored): osnadmin, configtxgen, peer,
│                              #   fabric-ca-client, ledgerutil (Fabric v3.1.4 + fabric-ca 1.5.19)
├── network/
│   ├── docker-compose.yaml    # 4 CAs + 4 orderers + 3 peers + 3 CouchDB
│   ├── configtx/configtx.yaml # perfil AuditChannel: BFT, ConsenterMapping (4 nós), V3_0, AnchorPeers
│   ├── organizations/         # material criptográfico gerado (gitignored)
│   ├── system-genesis-block/  # bloco gênese do canal (gerado)
│   └── scripts/
│       ├── env.sh                  # topologia, portas, helpers
│       ├── 01-bootstrap-cas.sh     # sobe as 4 CAs
│       ├── 02-enroll-identities.sh # enrola orderers, peers, admins, auditor-agent + MSPs de org
│       ├── 03-create-channel.sh    # gênese → osnadmin join (4) → peers + peer channel join
│       ├── 04-deploy-chaincode.sh  # package/install/approve/commit (lifecycle v2)
│       ├── verify-orderers.sh      # critério Fase 1
│       ├── verify-channel.sh       # critério Fase 2
│       ├── verify-chaincode.sh     # critério Fase 3
│       ├── verify-validations.sh   # integração Fase 4
│       ├── verify-agent.sh         # critério Fase 5
│       └── teardown.sh             # limpeza completa idempotente
├── chaincode/audit/           # chaincode Go (contract-api-go/v2)
│   ├── go.mod / main.go
│   ├── model/audit_log.go     # struct AuditLog
│   ├── contract/audit_contract.go + validation.go (+ testes, ≥80% cobertura)
│   └── META-INF/statedb/couchdb/indexes/  # indexResource/indexActor/indexTimestamp.json
├── client/                    # agente capturador Go (Fabric Gateway SDK + inotify)
│   ├── cmd/agent/{main.go,config.go}
│   ├── internal/{gateway,watcher,submitter}/
│   └── config/agent.yaml
├── tests/
│   ├── integrity/             # tamper_test.sh + README (cenários A/B/C)
│   └── caliper/               # benchmarks (workloads, configs, monitor Prometheus, relatório)
└── README.md
```

---

## 4. Dependências

| Dependência | Versão | Uso |
|---|---|---|
| Docker Engine / Compose v2 | 24+ / v2 | runtime de todos os componentes |
| Go | 1.24+ (testado 1.26) | chaincode e agente cliente |
| Node.js | 20+ | Hyperledger Caliper (benchmarks) |
| Hyperledger Fabric (imagens) | **3.1.4** | `fabric-orderer`, `fabric-peer`, `fabric-ccenv`, `fabric-baseos` |
| Fabric CA (imagem) | **1.5.19** | emissão de identidades MSP/TLS |
| CouchDB | **3.4.2** | world state (state database) por peer |
| Binários Fabric (em `./bin`) | 3.1.4 / 1.5.19 | `osnadmin`, `configtxgen`, `peer`, `fabric-ca-client`, `ledgerutil` |
| Bibliotecas Go | `fabric-contract-api-go/v2` 2.2.1, `fabric-gateway` 1.10.0, `fsnotify` 1.9.0 | chaincode/cliente |
| Caliper | 0.7.1 (`fabric-gateway` binding) | benchmarks de desempenho |

> A imagem `hyperledger/fabric-tools` **não** é publicada para a série v3.x; por isso as ferramentas
> de linha de comando (`osnadmin`, `configtxgen`, `peer`, `ledgerutil`) ficam em `./bin`, baixadas
> dos releases oficiais. `fabric-ca-client` também está em `./bin`.

### Obter os binários (uma vez)

```bash
mkdir -p bin && cd bin
curl -fsSL https://github.com/hyperledger/fabric/releases/download/v3.1.4/hyperledger-fabric-linux-amd64-3.1.4.tar.gz | tar -xz
curl -fsSL https://github.com/hyperledger/fabric-ca/releases/download/v1.5.19/hyperledger-fabric-ca-linux-amd64-1.5.19.tar.gz | tar -xz
mv bin/* . 2>/dev/null; rmdir bin 2>/dev/null   # achata para ./bin/*
cd ..
docker pull hyperledger/fabric-ca:1.5.19 && docker pull couchdb:3.4.2
```
(As imagens `fabric-orderer/peer/ccenv/baseos:3.1.4` devem estar presentes localmente.)

---

## 5. Chaincode `audit-chaincode`

### 5.1 Modelo de dados (`AuditLog`)

`actionId`, `timestamp` (RFC3339), `operation` (CREATE|READ|UPDATE|DELETE), `resource`, `actor`,
`actorOrg`, `contentHash` (SHA-256 hex), `previousContentHash`, `sessionId`, `sourceHost`,
`submitterMSP` (preenchido pelo chaincode).

### 5.2 Funções

| Função | Tipo | Descrição |
|---|---|---|
| `RegisterLog(actionId, timestamp, operation, resource, actor, contentHash, previousContentHash, sessionId, sourceHost)` | escrita | grava um log após validar §6.6 |
| `QueryLog(actionId)` | leitura | registro por id |
| `QueryLogsByResource(resource)` | leitura | via composite key `resource~timestamp~actionId` |
| `QueryLogsByActor(actor)` | leitura | via composite key `actor~timestamp~actionId` |
| `QueryLogsByTimeRange(start, end)` | leitura | rich query CouchDB (índice `timestamp`) |
| `GetLastHashForResource(resource)` | leitura | último `contentHash` do recurso (encadeamento) |

**Não há** funções de delete/update — a imutabilidade é garantida pela ausência delas.

### 5.3 Validações (executadas em ordem no `RegisterLog`)

1. **Unicidade** — `actionId` não pode existir.
2. **Identidade** — submitter MSP ∈ {HospitalMSP, GovernoMSP, AuditoriaMSP}.
3. **Coerência ator↔org** — `actor` no formato `user@orgkey` (`hospital`/`governo`/`auditoria`),
   cuja org deve casar com o MSP do submitter; grava `actorOrg`.
4. **Timestamp** — RFC3339, não mais de 5 min no futuro vs o timestamp **determinístico** da
   transação (`GetTxTimestamp`).
5. **Operação** — uma de CREATE/READ/UPDATE/DELETE.
6. **Formato de hash** — `contentHash`/`previousContentHash`, quando presentes, SHA-256 hex (64).
7. **Encadeamento** — CREATE: sem prev, content obrigatório; UPDATE: prev == último hash do
   recurso; DELETE: prev obrigatório, content vazio; READ: content opcional.

### 5.4 Endosso e capabilities

- Política: `AND('HospitalMSP.peer','GovernoMSP.peer','AuditoriaMSP.peer')` (as 3 orgs assinam).
- Capabilities do canal: **Channel `V3_0`** (pré-requisito do SmartBFT), Orderer `V2_0`,
  Application `V2_0` (habilita o lifecycle de chaincode v2.x).

---

## 6. Agente capturador (cliente)

Em `client/` (módulo Go `audit-agent`), roda como **Hospital** (identidade `auditor-agent@hospital`,
tipo *client* — menor privilégio):

1. Monitora um diretório via **inotify** (`fsnotify`): Create→CREATE, Write→UPDATE, Remove→DELETE
   (leituras não são capturáveis por inotify).
2. Calcula `contentHash` (SHA-256) do arquivo; recupera `previousContentHash` via
   `GetLastHashForResource`.
3. Submete `RegisterLog` pelo **Fabric Gateway SDK** com `WithEndorsingOrganizations` das 3 orgs;
   o peer-gateway coleta os endossos server-side. Retry com backoff exponencial; log local.

> **Modelo de conexão:** o Gateway SDK usa **uma** conexão a um peer-gateway (não a 3 peers + 2
> orderers como no modelo legado); o endosso multi-org é resolvido pelo peer via discovery/anchor
> peers. Config em `client/config/agent.yaml` (caminhos via `${FABRIC_AUDIT_ROOT}`/`${WATCH_DIR}`).

---

## 7. Uso (bootstrap completo)

Pré-requisitos da Seção 4 satisfeitos. A partir de `network/`:

```bash
cd network

# Fase 1 — sobe as 4 CAs e enrola as identidades
./scripts/01-bootstrap-cas.sh
./scripts/02-enroll-identities.sh
docker compose up -d \
  orderer.hospital.example.com orderer.governo.example.com \
  orderer.auditoria.example.com orderer.notarial.example.com
./scripts/verify-orderers.sh          # osnadmin channel list responde nos 4

# Fase 2 — cria o canal e sobe peers + CouchDB
./scripts/03-create-channel.sh
./scripts/verify-channel.sh           # peer channel list mostra audit-channel

# Fase 3/4 — empacota, instala, aprova e committa o chaincode (lifecycle v2)
./scripts/04-deploy-chaincode.sh
./scripts/verify-chaincode.sh         # RegisterLog + QueryLog manuais
./scripts/verify-validations.sh       # regras §6.6 + queries (integração)

# Fase 5 — agente capturador
./scripts/verify-agent.sh             # criar arquivo no dir monitorado → tx commitada
```

Rodar o agente manualmente:
```bash
export FABRIC_AUDIT_ROOT=<raiz do fabric-audit>  WATCH_DIR=/algum/diretorio
cd client && go run ./cmd/agent -config config/agent.yaml
```

### Limpeza

```bash
cd network && ./scripts/teardown.sh   # remove containers, volumes, material cripto e chaincode dev-*
docker compose -f ../tests/caliper/monitor/docker-compose.monitor.yaml down  # se o monitor estiver no ar
```

---

## 8. Testes

### 8.1 Unitários do chaincode (cobertura ≥ 80%)

```bash
cd chaincode/audit
go install github.com/maxbrunsfeld/counterfeiter/v6@latest
GOFLAGS=-mod=mod go generate ./contract/...     # gera mocks
GOFLAGS=-mod=mod go test ./contract/... -cover  # ~81.9%
```

### 8.2 Integridade / tampering (`tests/integrity/`)

Adulteração nas **duas camadas** do ledger, com detecção e recuperação (perturba e restaura só
peer0.hospital). Ver `tests/integrity/README.md`.

```bash
N=10 bash tests/integrity/tamper_test.sh
```
- **A — world state (CouchDB):** divergência cross-peer + falha de endosso `AND`; recuperação por
  `peer node rebuild-dbs` (reconstrói dos blocos).
- **B — block file:** `ledgerutil verify` detecta `DataHash mismatch`.
- **C — exclusão de block file:** o peer falha ao ler o ledger; recuperação re-provisionando do orderer.

### 8.3 Desempenho — Caliper (`tests/caliper/`)

```bash
bash tests/caliper/run-benchmark.sh
```
Workloads escrita/leitura/misto + varredura de carga (10–200 TPS) + queda de orderer; percentis
p50/p95/p99 via Prometheus. Ver `tests/caliper/README.md` e `tests/caliper/results/`.

**Resultados observados (execução representativa):** escrita escala até **~199 TPS** com p99 < 0.45 s
e **0 falhas**; sob **queda de 1 dos 4 orderers** a rede mantém **100 TPS sem falhas** (tolerância
BFT `f=1` confirmada); consultas `QueryLogsByTimeRange` de intervalo amplo saturam (recomendação:
limitar a janela — as queries por composite key são baratas).

---

## 10. Referências

- Documentação oficial: https://hyperledger-fabric.readthedocs.io/en/latest/
- Castro, M. (2001). *Practical Byzantine Fault Tolerance.*
- Schneier, B.; Kelsey, J. (1999). *Secure audit logs to support computer forensics.*
- Liang, X. et al. (2017). *ProvChain: A blockchain-based data provenance architecture…*
