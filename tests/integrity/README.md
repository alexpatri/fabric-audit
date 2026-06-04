# Testes de integridade (SPECS §10.1 / §11.6)

Demonstram a detecção de adulteração nas **duas camadas** do ledger do Hyperledger Fabric, cada
uma com um mecanismo de proteção distinto:

| Camada | Cenário | Mecanismo de integridade | Detecção |
|---|---|---|---|
| World state (CouchDB) | A | Replicação + validação cruzada | Divergência entre peers + falha de endosso `AND` |
| Block ledger (arquivo) | B | Encadeamento criptográfico (hash) | `ledgerutil verify` → `DataHash mismatch` |
| Block ledger (arquivo) | C | Protocolo de sincronização | Falha ao ler o ledger; re-sync a partir do orderer |

## Execução

```bash
# rede no ar + chaincode deployado (Fases 1–4); peer0.hospital é perturbado e restaurado
N=10 bash tests/integrity/tamper_test.sh   # N = nº de transações legítimas de fundo (§10.1 ex.: 100)
```
O script perturba **apenas peer0.hospital**, faz backup do que altera e o **restaura ao fim de
cada cenário**, deixando a rede saudável (verificação final compara os 3 peers).

## Fundamentação técnica (comportamento real do Fabric)

- **O world state (CouchDB) NÃO é hash-encadeado.** É uma materialização derivada dos blocos.
  Editar um documento diretamente no CouchDB **não** é auto-detectado pelo peer (não há hash por
  documento, nenhum log é emitido; na reinicialização o peer compara apenas o *savepoint*/altura,
  não re-deriva o estado). A adulteração só é evidente por **divergência entre as réplicas**.
- **O block ledger É hash-encadeado** (cada bloco carrega `PreviousHash` e `DataHash`). Porém o
  peer **não** re-verifica blocos históricos em operação normal nem no `rebuild-dbs` — só lê o
  último bloco no boot para determinar a altura. A verificação criptográfica explícita é feita
  pela ferramenta oficial **`ledgerutil verify`**, que recomputa o `DataHash` de cada bloco.
- **A cadeia autoritativa** vive nos orderers e nos peers honestos; o world state de qualquer peer
  é reconstruível a partir dos blocos (`peer node rebuild-dbs`).

## Cenário A — World state (CouchDB)

1. Submete N transações legítimas + um alvo `X` (resource `R`, `contentHash=H1`).
2. Para `peer0.hospital`; via API REST do CouchDB (`audit-channel_audit-chaincode`) adultera o doc
   `X` (altera `actor` e `contentHash`, mantendo `~version`); reinicia o peer (o cache de estado
   exige restart para servir o valor adulterado).
3. **A.5 (divergência):** `QueryLog(X)` retorna `HACKER@hospital` em hospital e `tester@hospital`
   em governo/auditoria → adulteração caracterizada e peer comprometido identificado.
4. **A.6 (endosso):** um `UPDATE` em `R` (que faz o chaincode ler o último hash via
   `GetLastHashForResource`) com endosso das 3 orgs **falha** — hospital reprova (`previousContentHash
   não coincide…`) enquanto os demais aprovam; as respostas de endosso divergem e a política `AND`
   não é satisfeita. Evidência: `proposal response` / `não coincide`.
5. **A.7 (recuperação):** `peer node rebuild-dbs` reconstrói o world state a partir dos blocos
   íntegros; a adulteração é sobrescrita (`actor` volta a `tester@hospital`).

## Cenário B — Block file (encadeamento criptográfico)

1. Para `peer0.hospital`; faz backup e inverte **1 byte** no meio de `blockfile_000000`.
2. Executa `ledgerutil verify /var/hyperledger/production` (peer offline).
3. **Detecção:** saída `Some error(s) are found` e `blocks.json` =
   `[{"blockNum":N,"valid":false,"errors":["DataHash mismatch"]}]` → o `DataHash` recomputado não
   bate com o header. A cadeia é localmente verificável e a adulteração é tamper-evident.
4. **Recuperação:** restaura o block file do backup.

## Cenário C — Exclusão de block file (sincronização)

1. Para `peer0.hospital`; faz backup e **remove** `blockfile_000000` (no Fabric os blocos ficam em
   arquivos append-only com muitos blocos cada; num ledger pequeno há um só = a cadeia inteira).
2. Reinicia o peer.
3. **Detecção:** o índice (leveldb) referencia offsets do arquivo removido; o peer entra em
   `panic` ao tentar ler o último bloco (`Could not open current file for detecting last block… bufio:
   negative count`) → falha ao carregar o ledger.
4. **Recuperação:** restaura o block file (no teste). Em produção, a recuperação canônica é
   **re-provisionar** o ledger do peer e re-sincronizar a partir do orderer (catch-up via deliver) —
   o Fabric não faz restore de bloco individual via gossip.

## Resultado

Os três cenários produzem evidência da detecção e o peer é recuperado em todos. Saída final:
`FASE 6 OK: cenários A, B e C detectados, documentados e recuperados.`
