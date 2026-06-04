# Benchmarks de desempenho — Hyperledger Caliper (SPECS §10.2 / §11.7)

Mede o `audit-chaincode` com **Caliper 0.7.1** (conector `fabric-gateway`), conectando a um
peer-gateway (peer0.hospital) com a identidade `auditor-agent@hospital`. O endosso das 3 orgs é
resolvido server-side pelo gateway.

## Execução

```bash
# rede + chaincode no ar (Fases 1–4); Node 20 no host
bash tests/caliper/run-benchmark.sh
```
O script: copia a identidade para `crypto/`, sobe Prometheus+Pushgateway, faz `npm install` +
`caliper bind fabric:fabric-gateway`, roda o benchmark principal e o de degradação, e extrai os
percentis. Saídas em `tests/caliper/results/`.

## Workloads (§10.2)

| Workload | Módulo | Operação |
|---|---|---|
| Escrita | `workloads/register-log.js` | `RegisterLog` (CREATE, args válidos §6.6) |
| Leitura | `workloads/query-log.js` | `QueryLogsByResource` (80%) / `QueryLogsByTimeRange` (20%), readOnly |
| Misto 80/20 | `workloads/mixed.js` | 80% escrita / 20% leitura |

## Rounds da execução representativa

`seed` (escrita, popula resources) → varredura de carga `sweep-10/50/100/200` (§10.3) →
`read` → `mixed-80-20`; e, separadamente, `degradation` (escrita sob queda de 1 orderer BFT).

## Métricas

- **Caliper (`report-*.html`):** Succ/Fail (taxa de falha), Send Rate (TPS submetido),
  Throughput (TPS commitado), latência **min/méd/máx**.
- **Percentis p50/p95/p99 (`percentiles.md`):** via Prometheus — o report HTML do Caliper **não**
  traz percentis. O monitor `prometheus-push` exporta o histograma `caliper_tx_e2e_latency` ao
  Pushgateway; `extract-percentiles.sh` calcula `histogram_quantile()` por `roundLabel`.

## Análise comparativa

- **Carga vs throughput/latência:** comparar `sweep-10/50/100/200` — o throughput acompanha o send
  rate até saturar; a partir daí a latência cresce e a taxa de falha pode subir.
- **Degradação (§10.3):** `degradation` vs `sweep-100` (mesma taxa) — com 1 dos 4 orderers fora, o
  BFT (f=1, quorum 3) mantém disponibilidade; espera-se um aumento transitório de latência e/ou
  pequena queda de throughput na janela da falha.

## Resultados observados (execução representativa)

| Round | Send TPS | Throughput TPS | Fail | méd (s) | p95 (s) | p99 (s) |
|---|---|---|---|---|---|---|
| sweep-10/50/100/200 (escrita) | 10→200 | 10→**198.8** | **0** | 0.11–0.18 | 0.17–0.26 | 0.19–0.45 |
| read (leitura) | 100 | 67.1 | 4043* | 4.18 | ~5.0 | ~5.0 |
| mixed-80-20 | 100 | 99.6 | 0 | 0.19 | 0.42 | 0.55 |
| degradation (1 orderer fora) | 100 | 99.8 | 0 | 0.11 | 0.18 | 0.20 |

- **Escrita escala até ~199 TPS** com latência sub-segundo e **0 falhas**; saturação não atingida a 200 TPS.
- **Degradação BFT:** com 1 dos 4 orderers parado, 100 TPS mantidos sem falhas (tolerância f=1 confirmada).
- *O round de leitura falha/satura por causa das `QueryLogsByTimeRange` de intervalo amplo (retornam o
  dataset inteiro) — **finding**: limitar a janela das rich queries; as queries por composite key são baratas.

Relatório completo da execução: `results/RELATORIO.md` (+ `report-main.html`, `report-degradation.html`).

## Matriz completa (§10.2/§10.3) — como rodar

A execução padrão usa rounds curtos. Para o protocolo integral:
- **5 minutos por round:** `txDuration: 300` em cada round.
- **3 repetições:** o Caliper não tem "repeat" — duplique cada bloco de round 3× (ou gere o YAML).
- **Variação de batch (§10.3):** alterar `BatchTimeout` (1s/2s/5s) exige uma **atualização de config
  do canal** entre execuções (`peer channel fetch config` → editar → `configtxlator` → assinar →
  `peer channel update`); rodar o mesmo benchmark após cada mudança e comparar.

## Caveats

- **Acurácia dos percentis:** `histogram_quantile` é interpolado e depende dos `histogramBuckets`
  (configurados linear 0.05/0.05/100). Para latências fora de 0.05–5 s, ajuste os buckets.
- Pré-requisito: peers com `CORE_PEER_GATEWAY_ENABLED=true` (default na v3.x).
- `crypto/` contém material privado copiado (efêmero, gitignored).

## Limpeza

```bash
docker compose -f tests/caliper/monitor/docker-compose.monitor.yaml down
```
