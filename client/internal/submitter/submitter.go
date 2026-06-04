// Package submitter monta e submete transações RegisterLog a partir de eventos de filesystem,
// com recuperação do hash anterior, retry/backoff exponencial e log local (SPECS §8.2).
package submitter

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log"
	mrand "math/rand"
	"os"
	"strings"
	"time"

	"audit-agent/internal/watcher"

	"github.com/hyperledger/fabric-gateway/pkg/client"
	"github.com/hyperledger/fabric-protos-go-apiv2/peer"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// Submitter encapsula o contrato e a política de submissão.
type Submitter struct {
	contract    *client.Contract
	actor       string
	sourceHost  string
	sessionID   string
	orgs        []string
	maxAttempts int
	baseBackoff time.Duration
	log         *log.Logger
}

func New(contract *client.Contract, actor, sourceHost, sessionID string, orgs []string,
	maxAttempts int, baseBackoff time.Duration, logger *log.Logger) *Submitter {
	if maxAttempts < 1 {
		maxAttempts = 1
	}
	return &Submitter{
		contract: contract, actor: actor, sourceHost: sourceHost, sessionID: sessionID,
		orgs: orgs, maxAttempts: maxAttempts, baseBackoff: baseBackoff, log: logger,
	}
}

// Handle processa um evento: deriva conteúdo/hash, recupera o hash anterior e submete RegisterLog.
func (s *Submitter) Handle(ev watcher.Event) {
	resource := ev.Path
	op := ev.Op
	var contentHash, prev string
	var err error

	switch op {
	case "CREATE":
		if contentHash, err = hashFile(resource); err != nil {
			s.log.Printf("ignorado (hash) resource=%s: %v", resource, err)
			return
		}
	case "UPDATE":
		if contentHash, err = hashFile(resource); err != nil {
			s.log.Printf("ignorado (hash) resource=%s: %v", resource, err)
			return
		}
		if prev, err = s.lastHash(resource); err != nil {
			s.log.Printf("ignorado (lastHash) resource=%s: %v", resource, err)
			return
		}
		if prev == "" {
			op = "CREATE" // sem histórico: trata como criação
		}
	case "DELETE":
		if prev, err = s.lastHash(resource); err != nil {
			s.log.Printf("ignorado (lastHash) resource=%s: %v", resource, err)
			return
		}
		if prev == "" {
			s.log.Printf("ignorado (DELETE sem histórico) resource=%s", resource)
			return
		}
	}

	actionID, err := randHex(16)
	if err != nil {
		s.log.Printf("ignorado (actionId) resource=%s: %v", resource, err)
		return
	}
	ts := time.Now().UTC().Format(time.RFC3339)
	args := []string{actionID, ts, op, resource, s.actor, contentHash, prev, s.sessionID, s.sourceHost}

	if err := s.submitWithRetry(args); err != nil {
		s.log.Printf("FALHA actionId=%s op=%s resource=%s: %v", actionID, op, resource, err)
		return
	}
	s.log.Printf("committed actionId=%s op=%s resource=%s", actionID, op, resource)
}

func (s *Submitter) lastHash(resource string) (string, error) {
	res, err := s.contract.Evaluate("GetLastHashForResource", client.WithArguments(resource))
	if err != nil {
		return "", err
	}
	// contractapi pode serializar strings com aspas; remove defensivamente.
	return strings.Trim(string(res), `"`), nil
}

func (s *Submitter) submitWithRetry(args []string) error {
	backoff := s.baseBackoff
	var last error
	for attempt := 1; attempt <= s.maxAttempts; attempt++ {
		_, err := s.contract.Submit("RegisterLog",
			client.WithArguments(args...),
			client.WithEndorsingOrganizations(s.orgs...),
		)
		if err == nil {
			return nil
		}
		last = err
		if !isRetryable(err) {
			return err
		}
		s.log.Printf("tentativa %d/%d falhou (retryable): %v", attempt, s.maxAttempts, err)
		time.Sleep(backoff + time.Duration(mrand.Int63n(int64(backoff)+1)))
		backoff *= 2
	}
	return fmt.Errorf("após %d tentativas: %w", s.maxAttempts, last)
}

// isRetryable: conflitos MVCC/PHANTOM e indisponibilidade transitória são retryáveis;
// falha de política de endosso e erros determinísticos não.
func isRetryable(err error) bool {
	var commitErr *client.CommitError
	if errors.As(err, &commitErr) {
		switch commitErr.Code {
		case peer.TxValidationCode_MVCC_READ_CONFLICT, peer.TxValidationCode_PHANTOM_READ_CONFLICT:
			return true
		default:
			return false
		}
	}
	switch status.Code(err) {
	case codes.Unavailable, codes.DeadlineExceeded, codes.Aborted:
		return true
	}
	return false
}

func hashFile(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func randHex(n int) (string, error) {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}
