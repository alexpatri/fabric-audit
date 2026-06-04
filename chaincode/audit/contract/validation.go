package contract

import (
	"fmt"
	"regexp"
	"time"
)

// Conjunto de MSPs autorizados a submeter logs (orgs de aplicação — §6.6 regra 2).
// NotarialMSP é só ordenação e não submete transações.
var allowedSubmitterMSP = map[string]bool{
	"HospitalMSP":  true,
	"GovernoMSP":   true,
	"AuditoriaMSP": true,
}

// Mapeia o orgkey usado na convenção de naming do ator (user@orgkey) para o MSP ID (§6.6 regra 3).
var orgKeyToMSP = map[string]string{
	"hospital":  "HospitalMSP",
	"governo":   "GovernoMSP",
	"auditoria": "AuditoriaMSP",
}

// Operações válidas (§6.6 regra 5).
var validOperations = map[string]bool{
	"CREATE": true, "READ": true, "UPDATE": true, "DELETE": true,
}

var (
	hashRegex  = regexp.MustCompile(`^[0-9a-f]{64}$`)
	actorRegex = regexp.MustCompile(`^([^@]+)@([a-z]+)$`)
)

const futureSkew = 5 * time.Minute

// validateSubmitterMSP — regra 2.
func validateSubmitterMSP(mspID string) error {
	if !allowedSubmitterMSP[mspID] {
		return fmt.Errorf("MSP '%s' não autorizado a submeter logs (regra 2)", mspID)
	}
	return nil
}

// validateActorOrg — regra 3: actor = "user@orgkey" e orgkey→MSP deve casar com o submitter.
func validateActorOrg(actor, submitterMSP string) error {
	m := actorRegex.FindStringSubmatch(actor)
	if m == nil {
		return fmt.Errorf("actor '%s' deve seguir a convenção 'user@orgkey' (regra 3)", actor)
	}
	orgKey := m[2]
	msp, ok := orgKeyToMSP[orgKey]
	if !ok {
		return fmt.Errorf("orgkey '%s' do actor desconhecido (regra 3)", orgKey)
	}
	if msp != submitterMSP {
		return fmt.Errorf("actor pertence a '%s' mas o submitter é '%s' (regra 3)", msp, submitterMSP)
	}
	return nil
}

// validateTimestamp — regra 4: RFC3339 e não mais de 5 min no futuro vs o timestamp da transação.
func validateTimestamp(timestamp string, peerTime time.Time) error {
	t, err := time.Parse(time.RFC3339, timestamp)
	if err != nil {
		return fmt.Errorf("timestamp '%s' não é RFC3339 válido (regra 4): %w", timestamp, err)
	}
	if t.After(peerTime.Add(futureSkew)) {
		return fmt.Errorf("timestamp '%s' está mais de 5min no futuro (regra 4)", timestamp)
	}
	return nil
}

// validateOperation — regra 5.
func validateOperation(operation string) error {
	if !validOperations[operation] {
		return fmt.Errorf("operação '%s' inválida; use CREATE|READ|UPDATE|DELETE (regra 5)", operation)
	}
	return nil
}

// validateHashFormat — regra 6: SHA-256 hex (64 chars) quando não vazio.
func validateHashFormat(name, hash string) error {
	if hash == "" {
		return nil
	}
	if !hashRegex.MatchString(hash) {
		return fmt.Errorf("%s deve ser SHA-256 hex de 64 caracteres (regra 6)", name)
	}
	return nil
}

// validateHashChaining — regra 7: regras por operação. lastHash é o contentHash do último
// registro do resource (string vazia se não houver), usado apenas no UPDATE.
func validateHashChaining(operation, contentHash, previousContentHash, lastHash string) error {
	switch operation {
	case "CREATE":
		if previousContentHash != "" {
			return fmt.Errorf("CREATE não pode ter previousContentHash (regra 7)")
		}
		if contentHash == "" {
			return fmt.Errorf("CREATE exige contentHash (regra 7)")
		}
	case "UPDATE":
		if contentHash == "" || previousContentHash == "" {
			return fmt.Errorf("UPDATE exige contentHash e previousContentHash (regra 7)")
		}
		if previousContentHash != lastHash {
			return fmt.Errorf("previousContentHash não coincide com o último hash do resource (regra 7)")
		}
	case "DELETE":
		if previousContentHash == "" {
			return fmt.Errorf("DELETE exige previousContentHash (regra 7)")
		}
		if contentHash != "" {
			return fmt.Errorf("DELETE não pode ter contentHash (regra 7)")
		}
	case "READ":
		// contentHash opcional; previousContentHash não exigido.
	}
	return nil
}

// actorOrgMSP devolve o MSP derivado da convenção do actor (para gravar em ActorOrg).
func actorOrgMSP(actor string) string {
	m := actorRegex.FindStringSubmatch(actor)
	if m == nil {
		return ""
	}
	return orgKeyToMSP[m[2]]
}
