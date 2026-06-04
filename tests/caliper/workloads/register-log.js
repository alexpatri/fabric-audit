'use strict';
// Workload de ESCRITA: submete RegisterLog com argumentos VÁLIDOS (passam as validações §6.6).
const { WorkloadModuleBase } = require('@hyperledger/caliper-core');
const crypto = require('crypto');

class RegisterLogWorkload extends WorkloadModuleBase {
    async initializeWorkloadModule(workerIndex, totalWorkers, roundIndex, roundArguments, sutAdapter, sutContext) {
        await super.initializeWorkloadModule(workerIndex, totalWorkers, roundIndex, roundArguments, sutAdapter, sutContext);
        this.txIndex = 0;
    }

    async submitTransaction() {
        this.txIndex++;
        const actionId = `act_${this.workerIndex}_${this.txIndex}_${Date.now()}`;
        const timestamp = new Date().toISOString();                 // RFC3339 (Go aceita fração de seg.)
        const resource = `/bench/r-${this.txIndex % 100}`;
        const contentHash = crypto.createHash('sha256').update(actionId).digest('hex'); // 64 hex
        await this.sutAdapter.sendRequests({
            contractId: 'audit-chaincode',
            contractFunction: 'RegisterLog',
            invokerIdentity: 'auditor-agent',
            contractArguments: [
                actionId, timestamp, 'CREATE', resource, 'bench@hospital',
                contentHash, '', `sess-${this.workerIndex}`, 'caliper'
            ],
            readOnly: false,
        });
    }
}

module.exports.createWorkloadModule = () => new RegisterLogWorkload();
