package contract_test

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"audit-chaincode/contract"
	"audit-chaincode/contract/mocks"
	"audit-chaincode/model"

	"github.com/hyperledger/fabric-protos-go-apiv2/ledger/queryresult"
	"github.com/stretchr/testify/require"
	"google.golang.org/protobuf/types/known/timestamppb"
)

const validHash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" // 64 hex
const otherHash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

func nowRFC3339() string { return time.Now().UTC().Format(time.RFC3339) }

// newCtx devolve um contexto fakeado com o MSP do submitter e tx-timestamp = agora.
func newCtx(msp string) (*mocks.TransactionContext, *mocks.ChaincodeStub) {
	stub := &mocks.ChaincodeStub{}
	ctx := &mocks.TransactionContext{}
	ctx.GetStubReturns(stub)
	clientID := &mocks.ClientIdentity{}
	clientID.GetMSPIDReturns(msp, nil)
	ctx.GetClientIdentityReturns(clientID)
	stub.GetTxTimestampReturns(timestamppb.New(time.Now()), nil)
	stub.SplitCompositeKeyStub = func(k string) (string, []string, error) {
		parts := strings.Split(k, "|")
		return parts[0], parts[1:], nil
	}
	return ctx, stub
}

// iterFrom constrói um StateQueryIterator fakeado a partir de KVs.
func iterFrom(kvs ...*queryresult.KV) *mocks.StateQueryIterator {
	it := &mocks.StateQueryIterator{}
	for i, kv := range kvs {
		it.HasNextReturnsOnCall(i, true)
		it.NextReturnsOnCall(i, kv, nil)
	}
	it.HasNextReturnsOnCall(len(kvs), false)
	return it
}

func ckKV(resource, ts, actionID string) *queryresult.KV {
	return &queryresult.KV{Key: "idx|" + resource + "|" + ts + "|" + actionID}
}

func mustJSON(t *testing.T, l model.AuditLog) []byte {
	t.Helper()
	b, err := json.Marshal(l)
	require.NoError(t, err)
	return b
}

// ---------------------------------------------------------------------------
// RegisterLog — caminho feliz
// ---------------------------------------------------------------------------

func TestRegisterLog_CreateOK(t *testing.T) {
	ctx, stub := newCtx("HospitalMSP")
	stub.GetStateReturns(nil, nil) // actionId não existe

	cc := &contract.AuditContract{}
	err := cc.RegisterLog(ctx, "act1", nowRFC3339(), "CREATE", "/r/1", "alice@hospital", validHash, "", "s", "h")
	require.NoError(t, err)
	require.Equal(t, 3, stub.PutStateCallCount()) // registro + 2 composite keys
}

func TestRegisterLog_UpdateOK_ChainsToLastHash(t *testing.T) {
	ctx, stub := newCtx("HospitalMSP")
	prev := model.AuditLog{ActionId: "act0", Resource: "/r/1", ContentHash: validHash}
	stub.GetStateStub = func(key string) ([]byte, error) {
		if key == "act0" {
			return mustJSON(t, prev), nil
		}
		return nil, nil // act1 (uniqueness) inexistente
	}
	// GetLastHashForResource itera a composite key do resource e acha act0.
	stub.GetStateByPartialCompositeKeyReturns(iterFrom(ckKV("/r/1", "2020-01-01T00:00:00Z", "act0")), nil)

	cc := &contract.AuditContract{}
	err := cc.RegisterLog(ctx, "act1", nowRFC3339(), "UPDATE", "/r/1", "alice@hospital", otherHash, validHash, "s", "h")
	require.NoError(t, err)
}

func TestRegisterLog_DeleteOK(t *testing.T) {
	ctx, stub := newCtx("GovernoMSP")
	stub.GetStateReturns(nil, nil)
	cc := &contract.AuditContract{}
	err := cc.RegisterLog(ctx, "actD", nowRFC3339(), "DELETE", "/r/2", "bob@governo", "", validHash, "", "h")
	require.NoError(t, err)
}

func TestRegisterLog_ReadOK(t *testing.T) {
	ctx, stub := newCtx("AuditoriaMSP")
	stub.GetStateReturns(nil, nil)
	cc := &contract.AuditContract{}
	err := cc.RegisterLog(ctx, "actR", nowRFC3339(), "READ", "/r/3", "carol@auditoria", "", "", "", "h")
	require.NoError(t, err)
}

// ---------------------------------------------------------------------------
// RegisterLog — rejeições §6.6 (uma por regra)
// ---------------------------------------------------------------------------

func TestRegisterLog_Rejections(t *testing.T) {
	tests := []struct {
		name                                            string
		msp, actionID, ts, op, resource, actor          string
		content, prev                                   string
		exists                                          bool   // regra 1
		want                                            string // trecho esperado no erro
	}{
		{"duplicado", "HospitalMSP", "a", nowRFC3339(), "CREATE", "/r", "alice@hospital", validHash, "", true, "regra 1"},
		{"msp_invalido", "NotarialMSP", "a", nowRFC3339(), "CREATE", "/r", "x@hospital", validHash, "", false, "regra 2"},
		{"ator_sem_org", "HospitalMSP", "a", nowRFC3339(), "CREATE", "/r", "alice", validHash, "", false, "regra 3"},
		{"ator_org_errada", "HospitalMSP", "a", nowRFC3339(), "CREATE", "/r", "alice@governo", validHash, "", false, "regra 3"},
		{"timestamp_invalido", "HospitalMSP", "a", "nao-rfc3339", "CREATE", "/r", "alice@hospital", validHash, "", false, "regra 4"},
		{"timestamp_futuro", "HospitalMSP", "a", time.Now().Add(10 * time.Minute).UTC().Format(time.RFC3339), "CREATE", "/r", "alice@hospital", validHash, "", false, "regra 4"},
		{"operacao_invalida", "HospitalMSP", "a", nowRFC3339(), "PURGE", "/r", "alice@hospital", validHash, "", false, "regra 5"},
		{"hash_malformado", "HospitalMSP", "a", nowRFC3339(), "CREATE", "/r", "alice@hospital", "zzz", "", false, "regra 6"},
		{"create_com_prev", "HospitalMSP", "a", nowRFC3339(), "CREATE", "/r", "alice@hospital", validHash, validHash, false, "regra 7"},
		{"delete_com_content", "HospitalMSP", "a", nowRFC3339(), "DELETE", "/r", "alice@hospital", validHash, validHash, false, "regra 7"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			ctx, stub := newCtx(tc.msp)
			if tc.exists {
				stub.GetStateReturns([]byte("existe"), nil)
			} else {
				stub.GetStateReturns(nil, nil)
			}
			cc := &contract.AuditContract{}
			err := cc.RegisterLog(ctx, tc.actionID, tc.ts, tc.op, tc.resource, tc.actor, tc.content, tc.prev, "", "h")
			require.Error(t, err)
			require.Contains(t, err.Error(), tc.want)
		})
	}
}

func TestRegisterLog_UpdateHashMismatch(t *testing.T) {
	ctx, stub := newCtx("HospitalMSP")
	prev := model.AuditLog{ActionId: "act0", ContentHash: validHash}
	stub.GetStateStub = func(key string) ([]byte, error) {
		if key == "act0" {
			return mustJSON(t, prev), nil
		}
		return nil, nil
	}
	stub.GetStateByPartialCompositeKeyReturns(iterFrom(ckKV("/r/1", "2020-01-01T00:00:00Z", "act0")), nil)
	cc := &contract.AuditContract{}
	// prev informado (otherHash) != último hash (validHash) -> regra 7 UPDATE
	err := cc.RegisterLog(ctx, "act1", nowRFC3339(), "UPDATE", "/r/1", "alice@hospital", validHash, otherHash, "", "h")
	require.Error(t, err)
	require.Contains(t, err.Error(), "regra 7")
}

// ---------------------------------------------------------------------------
// Queries
// ---------------------------------------------------------------------------

func TestQueryLog(t *testing.T) {
	ctx, stub := newCtx("HospitalMSP")
	want := model.AuditLog{ActionId: "act1", Resource: "/r/1", SubmitterMSP: "HospitalMSP"}
	stub.GetStateReturns(mustJSON(t, want), nil)
	cc := &contract.AuditContract{}
	got, err := cc.QueryLog(ctx, "act1")
	require.NoError(t, err)
	require.Equal(t, "act1", got.ActionId)

	// não encontrado
	stub.GetStateReturns(nil, nil)
	_, err = cc.QueryLog(ctx, "missing")
	require.Error(t, err)
}

func TestQueryLogsByResource(t *testing.T) {
	ctx, stub := newCtx("HospitalMSP")
	rec := model.AuditLog{ActionId: "act1", Resource: "/r/1", Actor: "alice@hospital"}
	stub.GetStateReturns(mustJSON(t, rec), nil)
	stub.GetStateByPartialCompositeKeyReturns(iterFrom(ckKV("/r/1", "2026-01-01T00:00:00Z", "act1")), nil)

	cc := &contract.AuditContract{}
	byRes, err := cc.QueryLogsByResource(ctx, "/r/1")
	require.NoError(t, err)
	require.Len(t, byRes, 1)
	require.Equal(t, "act1", byRes[0].ActionId)
}

func TestQueryLogsByActor(t *testing.T) {
	ctx, stub := newCtx("HospitalMSP")
	rec := model.AuditLog{ActionId: "act1", Resource: "/r/1", Actor: "alice@hospital"}
	stub.GetStateReturns(mustJSON(t, rec), nil)
	stub.GetStateByPartialCompositeKeyReturns(iterFrom(ckKV("alice@hospital", "2026-01-01T00:00:00Z", "act1")), nil)

	cc := &contract.AuditContract{}
	byActor, err := cc.QueryLogsByActor(ctx, "alice@hospital")
	require.NoError(t, err)
	require.Len(t, byActor, 1)
	require.Equal(t, "act1", byActor[0].ActionId)
}

func TestQueryLogsByTimeRange(t *testing.T) {
	ctx, stub := newCtx("HospitalMSP")
	rec := model.AuditLog{ActionId: "act1", Timestamp: "2026-03-01T00:00:00Z"}
	stub.GetQueryResultReturns(iterFrom(&queryresult.KV{Value: mustJSON(t, rec)}), nil)
	cc := &contract.AuditContract{}
	logs, err := cc.QueryLogsByTimeRange(ctx, "2026-01-01T00:00:00Z", "2026-12-31T23:59:59Z")
	require.NoError(t, err)
	require.Len(t, logs, 1)
	require.Equal(t, "act1", logs[0].ActionId)
}

func TestGetLastHashForResource(t *testing.T) {
	ctx, stub := newCtx("HospitalMSP")
	cc := &contract.AuditContract{}

	// vazio: sem registros
	stub.GetStateByPartialCompositeKeyReturns(iterFrom(), nil)
	h, err := cc.GetLastHashForResource(ctx, "/r/x")
	require.NoError(t, err)
	require.Equal(t, "", h)

	// dois registros: deve devolver o de maior timestamp
	rec := model.AuditLog{ActionId: "act2", ContentHash: otherHash}
	stub.GetStateReturns(mustJSON(t, rec), nil)
	stub.GetStateByPartialCompositeKeyReturns(iterFrom(
		ckKV("/r/y", "2026-01-01T00:00:00Z", "act1"),
		ckKV("/r/y", "2026-06-01T00:00:00Z", "act2"),
	), nil)
	h, err = cc.GetLastHashForResource(ctx, "/r/y")
	require.NoError(t, err)
	require.Equal(t, otherHash, h)
}
