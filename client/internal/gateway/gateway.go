// Package gateway estabelece a conexão com o peer-gateway via Fabric Gateway SDK.
// O cliente abre UMA conexão ao peer-gateway, que coleta os endossos das demais
// organizações server-side (discovery) e encaminha aos orderers.
package gateway

import (
	"crypto/x509"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/hyperledger/fabric-gateway/pkg/client"
	"github.com/hyperledger/fabric-gateway/pkg/hash"
	"github.com/hyperledger/fabric-gateway/pkg/identity"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
)

// Params reúne os dados necessários para conectar como uma identidade de uma org.
type Params struct {
	Endpoint           string // ex.: localhost:7051
	TLSCACertPath      string // CA TLS do peer-gateway
	ServerNameOverride string // ex.: peer0.hospital.example.com (deve estar no SAN)
	MSPID              string
	CertPath           string // signcert da identidade (auditor-agent)
	KeyPath            string // arquivo da chave OU diretório keystore (chave única)
}

// Connect devolve o Gateway e a conexão gRPC subjacente (ambos devem ser fechados pelo chamador).
func Connect(p Params) (*client.Gateway, *grpc.ClientConn, error) {
	conn, err := newGRPCConnection(p.Endpoint, p.TLSCACertPath, p.ServerNameOverride)
	if err != nil {
		return nil, nil, fmt.Errorf("conexão gRPC: %w", err)
	}

	id, err := newIdentity(p.MSPID, p.CertPath)
	if err != nil {
		conn.Close()
		return nil, nil, fmt.Errorf("identidade: %w", err)
	}
	sign, err := newSign(p.KeyPath)
	if err != nil {
		conn.Close()
		return nil, nil, fmt.Errorf("assinatura: %w", err)
	}

	gw, err := client.Connect(
		id,
		client.WithSign(sign),
		client.WithHash(hash.SHA256),
		client.WithClientConnection(conn),
		client.WithEvaluateTimeout(15*time.Second),
		client.WithEndorseTimeout(30*time.Second),
		client.WithSubmitTimeout(30*time.Second),
		client.WithCommitStatusTimeout(2*time.Minute),
	)
	if err != nil {
		conn.Close()
		return nil, nil, fmt.Errorf("client.Connect: %w", err)
	}
	return gw, conn, nil
}

func newGRPCConnection(endpoint, tlsCACertPath, serverName string) (*grpc.ClientConn, error) {
	pem, err := os.ReadFile(tlsCACertPath)
	if err != nil {
		return nil, err
	}
	cert, err := identity.CertificateFromPEM(pem)
	if err != nil {
		return nil, err
	}
	pool := x509.NewCertPool()
	pool.AddCert(cert)
	creds := credentials.NewClientTLSFromCert(pool, serverName)
	return grpc.NewClient("dns:///"+endpoint, grpc.WithTransportCredentials(creds))
}

func newIdentity(mspID, certPath string) (*identity.X509Identity, error) {
	pem, err := os.ReadFile(certPath)
	if err != nil {
		return nil, err
	}
	cert, err := identity.CertificateFromPEM(pem)
	if err != nil {
		return nil, err
	}
	return identity.NewX509Identity(mspID, cert)
}

func newSign(keyPath string) (identity.Sign, error) {
	pem, err := readKey(keyPath)
	if err != nil {
		return nil, err
	}
	pk, err := identity.PrivateKeyFromPEM(pem)
	if err != nil {
		return nil, err
	}
	return identity.NewPrivateKeySign(pk)
}

// readKey aceita um arquivo de chave ou um diretório keystore (com a única chave gerada pela CA).
func readKey(keyPath string) ([]byte, error) {
	info, err := os.Stat(keyPath)
	if err != nil {
		return nil, err
	}
	if !info.IsDir() {
		return os.ReadFile(keyPath)
	}
	entries, err := os.ReadDir(keyPath)
	if err != nil {
		return nil, err
	}
	for _, e := range entries {
		if !e.IsDir() {
			return os.ReadFile(filepath.Join(keyPath, e.Name()))
		}
	}
	return nil, fmt.Errorf("nenhuma chave encontrada em %s", keyPath)
}
