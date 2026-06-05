// Package model define a estrutura de dados do registro de auditoria (SPECS §6.3).
package model

// AuditLog é o registro forense de um evento de auditoria gravado no ledger.
// A imutabilidade é garantida pela ausência de funções de alteração/exclusão no chaincode.
type AuditLog struct {
	ActionId            string `json:"actionId"`
	Timestamp           string `json:"timestamp"`           // RFC3339
	Operation           string `json:"operation"`           // CREATE | UPDATE | DELETE
	Resource            string `json:"resource"`            // caminho do recurso afetado
	Actor               string `json:"actor"`               // identificador do usuário
	ActorOrg            string `json:"actorOrg"`            // organização do ator
	ContentHash         string `json:"contentHash"`         // SHA-256 hex (vazio para DELETE)
	PreviousContentHash string `json:"previousContentHash"` // SHA-256 hex (vazio para CREATE)
	SessionId           string `json:"sessionId,omitempty"`
	SourceHost          string `json:"sourceHost"`
	SubmitterMSP        string `json:"submitterMSP"` // preenchido pelo chaincode
}
