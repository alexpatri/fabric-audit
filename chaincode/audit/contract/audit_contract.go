// Package contract implementa o chaincode de auditoria (audit-chaincode).
// Fase 4 (SPECS §11.4): validações §6.6, queries §6.4 com composite keys e índices CouchDB §6.7.
package contract

import (
	"encoding/json"
	"fmt"

	"audit-chaincode/model"

	"github.com/hyperledger/fabric-contract-api-go/v2/contractapi"
)

const (
	indexResource = "resource~timestamp~actionId"
	indexActor    = "actor~timestamp~actionId"
)

// AuditContract expõe as transações do chaincode audit-chaincode.
type AuditContract struct {
	contractapi.Contract
}

// RegisterLog grava um novo registro de auditoria após aplicar as validações §6.6 (em ordem).
func (c *AuditContract) RegisterLog(
	ctx contractapi.TransactionContextInterface,
	actionId, timestamp, operation, resource, actor,
	contentHash, previousContentHash, sessionId, sourceHost string,
) error {
	stub := ctx.GetStub()

	// Regra 1 — unicidade.
	existing, err := stub.GetState(actionId)
	if err != nil {
		return fmt.Errorf("falha ao ler o ledger: %w", err)
	}
	if existing != nil {
		return fmt.Errorf("actionId '%s' já existe (regra 1)", actionId)
	}

	// Regra 2 — identidade do submitter.
	mspID, err := ctx.GetClientIdentity().GetMSPID()
	if err != nil {
		return fmt.Errorf("falha ao obter MSP do submitter: %w", err)
	}
	if err := validateSubmitterMSP(mspID); err != nil {
		return err
	}

	// Regra 3 — coerência ator↔org.
	if err := validateActorOrg(actor, mspID); err != nil {
		return err
	}

	// Regra 4 — timestamp (vs timestamp determinístico da transação).
	txTs, err := stub.GetTxTimestamp()
	if err != nil {
		return fmt.Errorf("falha ao obter timestamp da transação: %w", err)
	}
	if err := validateTimestamp(timestamp, txTs.AsTime()); err != nil {
		return err
	}

	// Regra 5 — operação.
	if err := validateOperation(operation); err != nil {
		return err
	}

	// Regra 6 — formato dos hashes.
	if err := validateHashFormat("contentHash", contentHash); err != nil {
		return err
	}
	if err := validateHashFormat("previousContentHash", previousContentHash); err != nil {
		return err
	}

	// Regra 7 — encadeamento de hash (UPDATE consulta o último hash do resource).
	lastHash := ""
	if operation == "UPDATE" {
		lastHash, err = c.GetLastHashForResource(ctx, resource)
		if err != nil {
			return fmt.Errorf("falha ao obter último hash do resource: %w", err)
		}
	}
	if err := validateHashChaining(operation, contentHash, previousContentHash, lastHash); err != nil {
		return err
	}

	// Persiste o registro.
	logEntry := model.AuditLog{
		ActionId:            actionId,
		Timestamp:           timestamp,
		Operation:           operation,
		Resource:            resource,
		Actor:               actor,
		ActorOrg:            actorOrgMSP(actor),
		ContentHash:         contentHash,
		PreviousContentHash: previousContentHash,
		SessionId:           sessionId,
		SourceHost:          sourceHost,
		SubmitterMSP:        mspID,
	}
	bytes, err := json.Marshal(logEntry)
	if err != nil {
		return fmt.Errorf("falha ao serializar AuditLog: %w", err)
	}
	if err := stub.PutState(actionId, bytes); err != nil {
		return fmt.Errorf("falha ao gravar no ledger: %w", err)
	}

	// Composite keys para as queries por resource e por ator (§6.7).
	if err := c.putCompositeKey(ctx, indexResource, []string{resource, timestamp, actionId}); err != nil {
		return err
	}
	if err := c.putCompositeKey(ctx, indexActor, []string{actor, timestamp, actionId}); err != nil {
		return err
	}
	return nil
}

func (c *AuditContract) putCompositeKey(ctx contractapi.TransactionContextInterface, index string, attrs []string) error {
	ck, err := ctx.GetStub().CreateCompositeKey(index, attrs)
	if err != nil {
		return fmt.Errorf("falha ao criar composite key '%s': %w", index, err)
	}
	if err := ctx.GetStub().PutState(ck, []byte{0x00}); err != nil {
		return fmt.Errorf("falha ao gravar composite key '%s': %w", index, err)
	}
	return nil
}

// QueryLog recupera um registro de auditoria pelo actionId.
func (c *AuditContract) QueryLog(ctx contractapi.TransactionContextInterface, actionId string) (*model.AuditLog, error) {
	bytes, err := ctx.GetStub().GetState(actionId)
	if err != nil {
		return nil, fmt.Errorf("falha ao ler o ledger: %w", err)
	}
	if bytes == nil {
		return nil, fmt.Errorf("registro de auditoria '%s' não encontrado", actionId)
	}
	var logEntry model.AuditLog
	if err := json.Unmarshal(bytes, &logEntry); err != nil {
		return nil, fmt.Errorf("falha ao desserializar AuditLog: %w", err)
	}
	return &logEntry, nil
}

// QueryLogsByResource devolve todos os registros de um resource (via composite key, ordenados por timestamp).
func (c *AuditContract) QueryLogsByResource(ctx contractapi.TransactionContextInterface, resource string) ([]*model.AuditLog, error) {
	return c.queryByCompositeKey(ctx, indexResource, resource)
}

// QueryLogsByActor devolve todos os registros de um ator (via composite key, ordenados por timestamp).
func (c *AuditContract) QueryLogsByActor(ctx contractapi.TransactionContextInterface, actor string) ([]*model.AuditLog, error) {
	return c.queryByCompositeKey(ctx, indexActor, actor)
}

// queryByCompositeKey itera o range parcial da composite key, extrai os actionIds e busca cada registro.
func (c *AuditContract) queryByCompositeKey(ctx contractapi.TransactionContextInterface, index, first string) ([]*model.AuditLog, error) {
	it, err := ctx.GetStub().GetStateByPartialCompositeKey(index, []string{first})
	if err != nil {
		return nil, fmt.Errorf("falha na consulta por composite key '%s': %w", index, err)
	}
	defer it.Close()

	logs := []*model.AuditLog{}
	for it.HasNext() {
		kv, err := it.Next()
		if err != nil {
			return nil, err
		}
		_, parts, err := ctx.GetStub().SplitCompositeKey(kv.Key)
		if err != nil {
			return nil, err
		}
		actionId := parts[len(parts)-1] // último atributo
		logEntry, err := c.QueryLog(ctx, actionId)
		if err != nil {
			return nil, err
		}
		logs = append(logs, logEntry)
	}
	return logs, nil
}

// QueryLogsByTimeRange devolve registros cujo timestamp ∈ [startTime, endTime] (rich query CouchDB, read-only).
func (c *AuditContract) QueryLogsByTimeRange(ctx contractapi.TransactionContextInterface, startTime, endTime string) ([]*model.AuditLog, error) {
	query := fmt.Sprintf(`{"selector":{"timestamp":{"$gte":%q,"$lte":%q}}}`, startTime, endTime)
	it, err := ctx.GetStub().GetQueryResult(query)
	if err != nil {
		return nil, fmt.Errorf("falha na rich query por timestamp: %w", err)
	}
	defer it.Close()

	logs := []*model.AuditLog{}
	for it.HasNext() {
		kv, err := it.Next()
		if err != nil {
			return nil, err
		}
		var logEntry model.AuditLog
		if err := json.Unmarshal(kv.Value, &logEntry); err != nil {
			return nil, fmt.Errorf("falha ao desserializar AuditLog: %w", err)
		}
		logs = append(logs, &logEntry)
	}
	return logs, nil
}

// GetLastHashForResource devolve o contentHash do último registro (maior timestamp) do resource,
// ou string vazia se não houver registros. Determinístico (composite key range) — seguro em escrita.
func (c *AuditContract) GetLastHashForResource(ctx contractapi.TransactionContextInterface, resource string) (string, error) {
	it, err := ctx.GetStub().GetStateByPartialCompositeKey(indexResource, []string{resource})
	if err != nil {
		return "", fmt.Errorf("falha ao consultar resource: %w", err)
	}
	defer it.Close()

	lastTimestamp := ""
	lastActionId := ""
	for it.HasNext() {
		kv, err := it.Next()
		if err != nil {
			return "", err
		}
		_, parts, err := ctx.GetStub().SplitCompositeKey(kv.Key)
		if err != nil {
			return "", err
		}
		ts, actionId := parts[1], parts[2]
		if ts >= lastTimestamp { // RFC3339 em UTC ordena lexicograficamente
			lastTimestamp = ts
			lastActionId = actionId
		}
	}
	if lastActionId == "" {
		return "", nil // resource ainda sem registros
	}
	logEntry, err := c.QueryLog(ctx, lastActionId)
	if err != nil {
		return "", err
	}
	return logEntry.ContentHash, nil
}
