// Package contract implementa o chaincode de auditoria.
// Fase 3 (SPECS §11.3): apenas RegisterLog e QueryLog. As regras de validação (§6.6),
// demais queries (§6.4) e índices CouchDB (§6.7) entram na Fase 4.
package contract

import (
	"encoding/json"
	"fmt"

	"audit-chaincode/model"

	"github.com/hyperledger/fabric-contract-api-go/v2/contractapi"
)

// AuditContract expõe as transações do chaincode audit-chaincode.
type AuditContract struct {
	contractapi.Contract
}

// RegisterLog grava um novo registro de auditoria sob a chave actionId.
// SubmitterMSP é preenchido pelo chaincode a partir da identidade do submitter.
// (Validações de §6.6 serão adicionadas na Fase 4.)
func (c *AuditContract) RegisterLog(
	ctx contractapi.TransactionContextInterface,
	actionId, timestamp, operation, resource, actor,
	contentHash, previousContentHash, sessionId, sourceHost string,
) error {
	mspID, err := ctx.GetClientIdentity().GetMSPID()
	if err != nil {
		return fmt.Errorf("falha ao obter MSP do submitter: %w", err)
	}

	logEntry := model.AuditLog{
		ActionId:            actionId,
		Timestamp:           timestamp,
		Operation:           operation,
		Resource:            resource,
		Actor:               actor,
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

	if err := ctx.GetStub().PutState(actionId, bytes); err != nil {
		return fmt.Errorf("falha ao gravar no ledger: %w", err)
	}
	return nil
}

// QueryLog recupera um registro de auditoria pelo actionId.
func (c *AuditContract) QueryLog(
	ctx contractapi.TransactionContextInterface,
	actionId string,
) (*model.AuditLog, error) {
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
