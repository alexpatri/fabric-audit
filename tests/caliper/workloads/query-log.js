'use strict';
// Workload de LEITURA (readOnly): QueryLogsByResource (limitado) e, em fração menor,
// QueryLogsByTimeRange (consulta mais pesada). Requer dados semeados por um round de escrita.
const { WorkloadModuleBase } = require('@hyperledger/caliper-core');

class QueryLogWorkload extends WorkloadModuleBase {
    async submitTransaction() {
        if (Math.random() < 0.8) {
            await this.sutAdapter.sendRequests({
                contractId: 'audit-chaincode',
                contractFunction: 'QueryLogsByResource',
                invokerIdentity: 'auditor-agent',
                contractArguments: [`/bench/r-${Math.floor(Math.random() * 100)}`],
                readOnly: true,
            });
        } else {
            await this.sutAdapter.sendRequests({
                contractId: 'audit-chaincode',
                contractFunction: 'QueryLogsByTimeRange',
                invokerIdentity: 'auditor-agent',
                contractArguments: ['2000-01-01T00:00:00Z', '2100-01-01T00:00:00Z'],
                readOnly: true,
            });
        }
    }
}

module.exports.createWorkloadModule = () => new QueryLogWorkload();
