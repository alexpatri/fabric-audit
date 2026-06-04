'use strict';
// Workload MISTO: writeRatio (default 0.8) de escritas RegisterLog, resto de leituras.
const { WorkloadModuleBase } = require('@hyperledger/caliper-core');
const crypto = require('crypto');

class MixedWorkload extends WorkloadModuleBase {
    async initializeWorkloadModule(workerIndex, totalWorkers, roundIndex, roundArguments, sutAdapter, sutContext) {
        await super.initializeWorkloadModule(workerIndex, totalWorkers, roundIndex, roundArguments, sutAdapter, sutContext);
        this.txIndex = 0;
        this.writeRatio = (roundArguments && roundArguments.writeRatio) || 0.8;
    }

    async submitTransaction() {
        if (Math.random() < this.writeRatio) {
            this.txIndex++;
            const actionId = `mix_${this.workerIndex}_${this.txIndex}_${Date.now()}`;
            const contentHash = crypto.createHash('sha256').update(actionId).digest('hex');
            return this.sutAdapter.sendRequests({
                contractId: 'audit-chaincode',
                contractFunction: 'RegisterLog',
                invokerIdentity: 'auditor-agent',
                contractArguments: [
                    actionId, new Date().toISOString(), 'CREATE', `/bench/r-${this.txIndex % 100}`,
                    'bench@hospital', contentHash, '', `sess-${this.workerIndex}`, 'caliper'
                ],
                readOnly: false,
            });
        }
        return this.sutAdapter.sendRequests({
            contractId: 'audit-chaincode',
            contractFunction: 'QueryLogsByResource',
            invokerIdentity: 'auditor-agent',
            contractArguments: [`/bench/r-${Math.floor(Math.random() * 100)}`],
            readOnly: true,
        });
    }
}

module.exports.createWorkloadModule = () => new MixedWorkload();
