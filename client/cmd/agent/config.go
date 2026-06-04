package main

import (
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

// Config espelha config/agent.yaml. Caminhos podem usar ${VAR} (expandido em runtime).
type Config struct {
	Channel   string `yaml:"channel"`
	Chaincode string `yaml:"chaincode"`
	MSPID     string `yaml:"mspID"`
	Gateway   struct {
		Endpoint           string `yaml:"endpoint"`
		TLSCACertPath      string `yaml:"tlsCACertPath"`
		ServerNameOverride string `yaml:"serverNameOverride"`
	} `yaml:"gateway"`
	Identity struct {
		CertPath string `yaml:"certPath"`
		KeyPath  string `yaml:"keyPath"`
	} `yaml:"identity"`
	EndorsingOrgs []string `yaml:"endorsingOrgs"`
	WatchDir      string   `yaml:"watchDir"`
	Actor         string   `yaml:"actor"`
	SourceHost    string   `yaml:"sourceHost"`
	Retry         struct {
		MaxAttempts   int `yaml:"maxAttempts"`
		BaseBackoffMs int `yaml:"baseBackoffMs"`
	} `yaml:"retry"`
}

// LoadConfig lê o arquivo, expande variáveis de ambiente e faz o parse YAML.
func LoadConfig(path string) (*Config, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	expanded := os.ExpandEnv(string(raw))
	var c Config
	if err := yaml.Unmarshal([]byte(expanded), &c); err != nil {
		return nil, err
	}
	if c.Channel == "" || c.Chaincode == "" || c.WatchDir == "" || c.Actor == "" {
		return nil, fmt.Errorf("config incompleta (channel/chaincode/watchDir/actor obrigatórios)")
	}
	if c.SourceHost == "" {
		c.SourceHost, _ = os.Hostname()
	}
	if c.Retry.MaxAttempts == 0 {
		c.Retry.MaxAttempts = 5
	}
	if c.Retry.BaseBackoffMs == 0 {
		c.Retry.BaseBackoffMs = 500
	}
	return &c, nil
}
