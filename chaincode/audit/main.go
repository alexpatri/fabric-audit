// Chaincode audit-chaincode — registro forense imutável de eventos de auditoria.
package main

import (
	"log"

	"audit-chaincode/contract"

	"github.com/hyperledger/fabric-contract-api-go/v2/contractapi"
)

func main() {
	cc, err := contractapi.NewChaincode(&contract.AuditContract{})
	if err != nil {
		log.Panicf("erro ao criar audit-chaincode: %v", err)
	}
	if err := cc.Start(); err != nil {
		log.Panicf("erro ao iniciar audit-chaincode: %v", err)
	}
}
