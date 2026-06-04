// Agente capturador: monitora um diretório via inotify e submete RegisterLog ao audit-channel
// usando o Fabric Gateway SDK (SPECS §8).
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"flag"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"audit-agent/internal/gateway"
	"audit-agent/internal/submitter"
	"audit-agent/internal/watcher"
)

func main() {
	cfgPath := flag.String("config", "config/agent.yaml", "caminho do agent.yaml")
	flag.Parse()

	logger := log.New(os.Stdout, "[audit-agent] ", log.LstdFlags|log.LUTC)

	cfg, err := LoadConfig(*cfgPath)
	if err != nil {
		logger.Fatalf("config: %v", err)
	}

	gw, conn, err := gateway.Connect(gateway.Params{
		Endpoint:           cfg.Gateway.Endpoint,
		TLSCACertPath:      cfg.Gateway.TLSCACertPath,
		ServerNameOverride: cfg.Gateway.ServerNameOverride,
		MSPID:              cfg.MSPID,
		CertPath:           cfg.Identity.CertPath,
		KeyPath:            cfg.Identity.KeyPath,
	})
	if err != nil {
		logger.Fatalf("gateway: %v", err)
	}
	defer conn.Close()
	defer gw.Close()

	contract := gw.GetNetwork(cfg.Channel).GetContract(cfg.Chaincode)

	sessionID, _ := randSession()
	sub := submitter.New(
		contract, cfg.Actor, cfg.SourceHost, sessionID, cfg.EndorsingOrgs,
		cfg.Retry.MaxAttempts, time.Duration(cfg.Retry.BaseBackoffMs)*time.Millisecond, logger,
	)

	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()

	events := make(chan watcher.Event, 64)
	go func() {
		if err := watcher.Watch(ctx, cfg.WatchDir, events, logger); err != nil && ctx.Err() == nil {
			logger.Printf("watcher encerrado: %v", err)
			cancel()
		}
	}()

	logger.Printf("agente iniciado (org=%s, canal=%s, cc=%s, sessão=%s)", cfg.MSPID, cfg.Channel, cfg.Chaincode, sessionID)
	for {
		select {
		case <-ctx.Done():
			logger.Printf("encerrando...")
			return
		case ev := <-events:
			sub.Handle(ev)
		}
	}
}

func randSession() (string, error) {
	b := make([]byte, 8)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}
