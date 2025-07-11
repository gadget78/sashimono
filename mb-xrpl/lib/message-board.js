const fs = require('fs');
const evernode = require('evernode-js-client');
const { SqliteDatabase, DataTypes } = require('./sqlite-handler');
const { appenv } = require('./appenv');
const { SashiCLI } = require('./sashi-cli');
const { ConfigHelper } = require('./config-helper');
const { GovernanceManager } = require('./governance-manager');
const path = require('path');
const { UtilHelper } = require('./util-helper');

const LEASE_ID_REG_EXP = /^[0-9A-F]{64}$/;

const LeaseStatus = {
    ACQUIRING: 'Acquiring',
    ACQUIRED: 'Acquired',
    FAILED: 'Failed',
    DESTROYED: 'Destroyed',
    BURNED: 'Burned',
    SASHI_TIMEOUT: 'SashiTimeout',
    EXTENDED: 'Extended'
}

class MessageBoard {
    #leaseUpdateLock = false; // This locking mechanism is temporary, can be removed when acquire queue is implemented
    #xrplHalted = false;
    #graceThreshold = 0.25;
    #haltTimeout = 60; // In seconds
    #instanceExpirationQueue = [];
    #graceTimeoutRef = null;
    #lastHaltedTime = null;
    #concurrencyQueue = {
        processing: false,
        queue: []
    };
    #applyFeeUpliftment = false;
    #heartbeatRetryDelay = 300000; // 5 mins
    #heartbeatRetryCount = 3;
    #feeUpliftment = 0;
    #rebateMaxDelay = 60000; // 1 min

    constructor(configPath, dbPath, sashiCliPath, sashiDbPath, sashiConfigPath, reputationDConfigPath = null) {
        this.configPath = configPath;
        this.reputationDConfigPath = reputationDConfigPath;
        this.leaseTable = appenv.DB_TABLE_NAME;
        this.utilTable = appenv.DB_UTIL_TABLE_NAME;
        this.expiryList = [];
        this.activeInstanceCount = 0;

        if (!fs.existsSync(sashiCliPath))
            throw `Sashi CLI does not exist in ${sashiCliPath}.`;

        this.sashiCli = new SashiCLI(sashiCliPath, appenv.IS_DEV_MODE ? { DATA_DIR: path.join(appenv.DATA_DIR, '../') } : {});
        this.db = new SqliteDatabase(dbPath);
        this.sashiDb = new SqliteDatabase(sashiDbPath);
        this.sashiTable = appenv.SASHI_TABLE_NAME;
        this.sashiConfigPath = sashiConfigPath;
        this.governanceManager = new GovernanceManager(appenv.GOVERNANCE_CONFIG_PATH);
    }

    async init() {
        this.readConfig();
        if (!this.cfg.version || !this.cfg.xrpl.address || !this.cfg.xrpl.secret || !this.cfg.xrpl.governorAddress)
            throw "Required cfg fields cannot be empty.";

        await evernode.Defaults.useNetwork(this.cfg.xrpl.network || appenv.NETWORK);

        if (this.cfg.xrpl.governorAddress)
            evernode.Defaults.set({
                governorAddress: this.cfg.xrpl.governorAddress
            });

        if (this.cfg.xrpl.rippledServer)
            evernode.Defaults.set({
                rippledServer: this.cfg.xrpl.rippledServer
            });

        if (this.cfg.xrpl.fallbackRippledServers && this.cfg.xrpl.fallbackRippledServers.length)
            evernode.Defaults.set({
                fallbackRippledServers: this.cfg.xrpl.fallbackRippledServers
            });

        this.xrplApi = new evernode.XrplApi();
        evernode.Defaults.set({
            xrplApi: this.xrplApi
        })
        await this.xrplApi.connect();

        this.hostClient = new evernode.HostClient(this.cfg.xrpl.address, this.cfg.xrpl.secret);
        await this.#connectHost();

        console.log("Using,");
        console.log("\tGovernor account " + this.cfg.xrpl.governorAddress);
        console.log("\tRegistry account " + this.hostClient.config.registryAddress);
        console.log("\tHeartbeat account " + this.hostClient.config.heartbeatAddress);
        console.log("Using rippled " + this.cfg.xrpl.rippledServer);

        // Get last heartbeat moment from the host info.
        let hostInfo = await this.hostClient.getRegistration();
        if (!hostInfo)
            throw "Host is not registered.";

        this.regClient = await evernode.HookClientFactory.create(evernode.HookTypes.registry, { config: this.hostClient.config });

        await this.#connectRegistry({ skipConfigs: true });
        await this.regClient.subscribe();

        // Get moment only if heartbeat info is not 0.
        this.lastHeartbeatMoment = hostInfo.lastHeartbeatIndex ? await this.hostClient.getMoment(hostInfo.lastHeartbeatIndex) : 0;
        this.lastValidatedLedgerIndex = this.xrplApi.ledgerIndex;

        this.db.open();
        // Create lease table if not exist.
        await this.createLeaseTableIfNotExists();
        await this.createUtilDataTableIfNotExists();


        const leaseRecords = (await this.getLeaseRecords()).filter(r => (r.status === LeaseStatus.ACQUIRED || r.status === LeaseStatus.EXTENDED));
        for (const lease of leaseRecords)
            this.addToExpiryList(lease.tx_hash, lease.container_name, lease.tenant_xrp_address, this.getExpiryTimestamp(lease.timestamp, lease.life_moments));

        // Catch up missed transactions based on the previously updated "last_watched_ledger" record (checkpoint).
        await this.#catchupMissedLeases().catch(console.error);

        this.db.close();

        // Load the sashimono config.
        const sashiConfig = ConfigHelper.readSashiConfig(this.sashiConfigPath);
        this.activeInstanceCount = this.expiryList.length;
        console.log(`Active instance count: ${this.activeInstanceCount}`);

        // Update only if changed.
        const ramMb = Math.floor((sashiConfig.system.max_mem_kbytes + sashiConfig.system.max_swap_kbytes) / 1000);
        const diskMb = Math.floor(sashiConfig.system.max_storage_kbytes / 1000);
        const cpuMicroSec = sashiConfig.system.max_cpu_us;
        const totalInstanceCount = sashiConfig.system.max_instance_count;

        const availableLeaseOffers = await this.hostClient.getLeaseOffers();
        if (availableLeaseOffers.length > 0 && (Number(availableLeaseOffers[0].Amount?.value) !== this.cfg.xrpl.leaseAmount)) {
            console.log("Lease amount inconsistency was found with existing leases.");
            console.log(`Using previous lease amount as ${Number(availableLeaseOffers[0].Amount?.value)} EVRs.`);
            this.cfg.xrpl.leaseAmount = parseFloat(availableLeaseOffers[0].Amount?.value);
            this.persistConfig();
        }

        const version = this.cfg.version;
        if (!(hostInfo.maxInstances === totalInstanceCount &&
            hostInfo.activeInstances === this.activeInstanceCount &&
            hostInfo.version === version &&
            hostInfo.cpuMicrosec === cpuMicroSec &&
            hostInfo.ramMb === ramMb &&
            hostInfo.diskMb === diskMb &&
            parseFloat(hostInfo.leaseAmount) === this.cfg.xrpl.leaseAmount)) {
            await this.#queueAction(async (submissionRefs) => {
                submissionRefs.refs ??= [{}];
                // Check again wether the transaction is validated before retry.
                const txHash = submissionRefs?.refs[0]?.submissionResult?.result?.tx_json?.hash;
                if (txHash) {
                    const txResponse = await this.hostClient.xrplApi.getTransactionValidatedResults(txHash);
                    if (txResponse && txResponse.code === "tesSUCCESS") {
                        console.log('Transaction is validated and success, Retry skipped!')
                        return;
                    }
                }
                // Update the registry with the active instance count.
                await this.hostClient.updateRegInfo(this.activeInstanceCount, this.cfg.version, totalInstanceCount, null, null, cpuMicroSec, ramMb, diskMb, null, null, this.cfg.xrpl.leaseAmount, { submissionRef: submissionRefs?.refs[0] });
            });
        }

        // Update host additional information if necessary.
        if (sashiConfig?.hp?.host_address) {
            await this.#queueAction(async (submissionRefs) => {
                submissionRefs.refs ??= [{}];
                // Check again wether the transaction is validated before retry.
                const txHash = submissionRefs?.refs[0]?.submissionResult?.result?.tx_json?.hash;
                if (txHash) {
                    const txResponse = await this.hostClient.xrplApi.getTransactionValidatedResults(txHash);
                    if (txResponse && txResponse.code === "tesSUCCESS") {
                        console.log('Transaction is validated and success, Retry skipped!')
                        return;
                    }
                }
                // Prepare the host account if it has not been prepared properly.
                await this.hostClient.prepareAccount(sashiConfig.hp.host_address, { submissionRef: submissionRefs?.refs[0] });
            });
        }

        this.xrplApi.on(evernode.XrplApiEvents.DISCONNECTED, async (e) => {
            console.log(`Exiting due to server disconnect (code ${e})...`);
            process.exit(1);
        });


        this.xrplApi.on(evernode.XrplApiEvents.SERVER_DESYNCED, async (e) => {
            console.log(`Exiting due to server desync condition...`);
            process.exit(1);
        });

        this.xrplApi.on(evernode.XrplApiEvents.LEDGER, async (e) => {
            this.lastValidatedLedgerIndex = e.ledger_index;
            this.lastLedgerTime = evernode.UtilHelpers.getCurrentUnixTime('milli');
        });

        this.hostClient.on(evernode.HostEvents.AcquireLease, r => this.handleAcquireLease(r));
        this.hostClient.on(evernode.HostEvents.ExtendLease, r => this.handleExtendLease(r));
        this.hostClient.on(evernode.HostEvents.TerminateLease, r => this.handleTerminateLease(r));

        let hostRegFee = this.hostClient.config.hostRegFee;
        const checkAndRequestRebate = async () => {
            await this.#queueAction(async (submissionRefs) => {
                console.log("Checking for rebates...");
                submissionRefs.refs ??= [{}];
                // Check again wether the transaction is validated before retry.
                const txHash = submissionRefs?.refs[0]?.submissionResult?.result?.tx_json?.hash;
                if (txHash) {
                    const txResponse = await this.hostClient.xrplApi.getTransactionValidatedResults(txHash);
                    if (txResponse && txResponse.code === "tesSUCCESS") {
                        console.log('Transaction is validated and success, Retry skipped!')
                        return;
                    }
                }
                // Send rebate request at startup if there's any pending rebates..
                if (hostInfo?.registrationFee > hostRegFee) {
                    console.log(`Requesting rebates ${hostInfo?.registrationFee - hostRegFee} EVRs...`);
                    await this.hostClient.requestRebate({ submissionRef: submissionRefs?.refs[0] });
                }
            });
        }

        if (hostInfo?.registrationFee > hostRegFee) {
            await checkAndRequestRebate();
        }

        let rebateRequestPending = false;
        // Listen to the host registrations and send rebate requests if registration fee updated.
        this.regClient.on(evernode.RegistryEvents.HostRegistered, async r => {
            if (rebateRequestPending)
                return;

            try {
                await this.hostClient.refreshConfig();
                if (hostRegFee != this.hostClient.config.hostRegFee) {
                    hostRegFee = this.hostClient.config.hostRegFee;
                    hostInfo = await this.hostClient.getRegistration();
                    const delay = Math.floor(Math.random() * this.#rebateMaxDelay);
                    console.log(`Rebate request scheduled to start in ${delay} milliseconds.`);
                    rebateRequestPending = true;
                    setTimeout(async () => {
                        await checkAndRequestRebate().catch(console.error);
                        rebateRequestPending = false;
                    }, delay);
                }
            } catch (e) {
                console.error("Issue occurred while checking and requesting rebates.")
                console.error(e);
            }
        });

        // Offer if there are any unoffered leases.
        await this.#offerUnofferedLeases();

        // Fix lease inconsistencies.
        await this.#fixLeaseInconsistencies();

        // Start a job to expire instances and check for halts
        this.#startSashimonoClockScheduler();

        // Start heartbeat job
        this.#startHeartBeatScheduler();

        // Start a job to prune the orphan instances.
        this.#startPruneScheduler();

    }

    #prepareHostClientFunctionOptions() {
        let options = {}
        if (this.#applyFeeUpliftment) {
            options.transactionOptions = { feeUplift: this.#feeUpliftment }
        }

        return options;
    }

    // Try to acquire the lease update lock.
    async #acquireConcurrencyQueue() {
        await new Promise(async resolve => {
            while (this.#concurrencyQueue.processing) {
                await new Promise(resolveSleep => {
                    setTimeout(resolveSleep, 1000);
                })
            }
            resolve();
        });
        this.#concurrencyQueue.processing = true;
    }

    // Release the lease update lock.
    async #releaseConcurrencyQueue() {
        this.#concurrencyQueue.processing = false;
    }

    async #queueAction(action, maxAttempts = 5, delay = 0) {
        await this.#acquireConcurrencyQueue();

        this.#concurrencyQueue.queue.push({
            callback: action,
            submissionRefs: {},
            attempts: 0,
            maxAttempts: maxAttempts,
            delay: delay
        });

        await this.#releaseConcurrencyQueue();
    }

    async #processConcurrencyQueue() {
        await this.#acquireConcurrencyQueue();

        let toKeep = [];
        for (let action of this.#concurrencyQueue.queue) {
            try {
                await action.callback(action.submissionRefs);
                this.#applyFeeUpliftment = false;
                this.#feeUpliftment = 0;
            }
            catch (e) {
                if (action.attempts < action.maxAttempts) {
                    action.attempts++;
                    console.error(`Queue action failed. Retrying attempt ${action.attempts}`, e);

                    if (this.cfg.xrpl.affordableExtraFee > 0 && e.status === "TOOK_LONG") {
                        this.#applyFeeUpliftment = true;
                        this.#feeUpliftment = Math.floor((this.cfg.xrpl.affordableExtraFee * action.attempts) / action.maxAttempts);
                    }
                    if (action.delay > 0) {
                        new Promise((resolve) => {
                            const checkFlagInterval = setInterval(() => {
                                if (!this.#concurrencyQueue.processing) {
                                    this.#concurrencyQueue.queue.push(action);
                                    clearInterval(checkFlagInterval);
                                    resolve();
                                }
                            }, action.delay);
                        });
                    } else
                        toKeep.push(action);
                }
                else {
                    console.error(e);
                }
            }
        }
        this.#concurrencyQueue.queue = toKeep;

        await this.#releaseConcurrencyQueue();
    }

    // Check for xrpl halts
    #checkLedgersForHalt() {
        const currentTime = evernode.UtilHelpers.getCurrentUnixTime('milli');
        const lastLedgerTimeDifference = currentTime - this.lastLedgerTime;

        if (lastLedgerTimeDifference >= this.#haltTimeout * 1000) {
            if (!this.#xrplHalted) {
                this.#xrplHalted = true;
                this.#lastHaltedTime = this.lastLedgerTime;
            } else if (this.#graceTimeoutRef) {
                clearTimeout(this.#graceTimeoutRef);
                this.#graceTimeoutRef = null;
            }
        }

        if (this.#xrplHalted && lastLedgerTimeDifference < (this.#haltTimeout * 1000) && !this.#graceTimeoutRef) {
            const haltedDuration = currentTime - this.#lastHaltedTime; // in milliSec
            const gracePeriod = haltedDuration * this.#graceThreshold;
            this.#graceTimeoutRef = setTimeout(() => {
                this.#xrplHalted = false;
                this.#graceTimeoutRef = null;
            }, gracePeriod);
        }
    }

    async #fixLeaseInconsistencies() {
        console.log("Checking for inconsistent leases...");

        try {
            const leaseAmount = this.cfg.xrpl.leaseAmount;
            const outboundSubnet = this.cfg.networking?.ipv6?.subnet;

            const sashiConfig = ConfigHelper.readSashiConfig(this.sashiConfigPath);
            const totalInstanceCount = sashiConfig.system.max_instance_count;


            this.db.open();
            const leaseRecords = (await this.getLeaseRecords()).filter(i => (i.status === LeaseStatus.ACQUIRED || i.status === LeaseStatus.EXTENDED));
            this.db.close();
            const soldCount = leaseRecords.length;

            if (totalInstanceCount && soldCount <= totalInstanceCount) {
                // Get unsold URI Tokens.
                const unsoldUriTokens = (await this.hostClient.xrplAcc.getURITokens()).filter(n => n.Issuer == this.hostClient.xrplAcc.address && evernode.EvernodeHelpers.isValidURI(n.URI, evernode.EvernodeConstants.LEASE_TOKEN_PREFIX_HEX))
                    .map(n => { return { uriTokenId: n.index, leaseIndex: evernode.UtilHelpers.decodeLeaseTokenUri(n.URI).leaseIndex }; });
                const unsoldCount = unsoldUriTokens.length;

                async function getVacantLeaseIndexes(includeUnsold = true) {
                    let acquired = includeUnsold ? [] : unsoldUriTokens.map(n => n.leaseIndex);
                    let vacant = [];
                    for (const l of leaseRecords) {
                        try {
                            const uriTokenId = l.container_name;
                            const uriToken = (await this.hostClient.getLeaseByIndex(uriTokenId));
                            if (uriToken) {
                                const index = evernode.UtilHelpers.decodeLeaseTokenUri(uriToken.URI).leaseIndex;
                                acquired.push(index);
                            }
                        } catch {
                        }
                    }
                    let i = 0;
                    while (vacant.length + acquired.length < totalInstanceCount) {
                        if (!acquired.includes(i))
                            vacant.push(i);
                        i++;
                    }
                    return vacant;
                }

                let uriTokensToBurn = [];
                let uriTokenIndexesToCreate = [];
                if (totalInstanceCount && (soldCount + unsoldCount) !== totalInstanceCount) {
                    if (totalInstanceCount < soldCount + unsoldCount) {
                        uriTokensToBurn = unsoldUriTokens.sort((a, b) => a.leaseIndex - b.leaseIndex).slice(totalInstanceCount - soldCount);
                        uriTokenIndexesToCreate = [];
                    }
                    else {
                        uriTokensToBurn = [];
                        uriTokenIndexesToCreate = await getVacantLeaseIndexes(false);
                    }
                }

                for (const uriToken of uriTokensToBurn) {
                    await this.#queueAction(async (submissionRefs) => {
                        submissionRefs.refs ??= [{}];
                        // Check again wether the transaction is validated before retry.
                        const txHash = submissionRefs?.refs[0]?.submissionResult?.result?.tx_json?.hash;
                        if (txHash) {
                            const txResponse = await this.hostClient.xrplApi.getTransactionValidatedResults(txHash);
                            if (txResponse && txResponse.code === "tesSUCCESS") {
                                console.log('Transaction is validated and success, Retry skipped!')
                                return;
                            }
                        }
                        await this.hostClient.expireLease(uriToken.uriTokenId, { submissionRef: submissionRefs?.refs[0] });
                    });
                    console.log(`Queued lease expiry.`);
                }

                for (const idx of uriTokenIndexesToCreate) {
                    await this.#queueAction(async (submissionRefs) => {
                        submissionRefs.refs ??= [{}];
                        // Check again wether the transaction is validated before retry.
                        const txHash = submissionRefs?.refs[0]?.submissionResult?.result?.tx_json?.hash;
                        if (txHash) {
                            const txResponse = await this.hostClient.xrplApi.getTransactionValidatedResults(txHash);
                            if (txResponse && txResponse.code === "tesSUCCESS") {
                                console.log('Transaction is validated and success, Retry skipped!')
                                return;
                            }
                        }
                        await this.hostClient.offerLease(idx,
                            leaseAmount,
                            appenv.TOS_HASH,
                            (outboundSubnet) ? UtilHelper.generateIPV6Address(outboundSubnet, idx) : null, { submissionRef: submissionRefs?.refs[0] });
                    });
                    console.log(`Queued lease create.`);
                }
            }

            console.log("Inconsistent lease check completed.");
        }
        catch (e) {
            console.log("Error occurred in lease inconsistency check.", e);
        }
    }

    async #offerUnofferedLeases() {
        console.log("Checking for unoffered leases...");

        try {
            const unoffered = await this.hostClient.getUnofferedLeases();
            if (unoffered.length > 0) {
                // Create lease offers.
                console.log("Creating lease offers for instance slots...");
                let i = 0;
                for (let t of unoffered) {
                    const uriInfo = evernode.UtilHelpers.decodeLeaseTokenUri(t.URI);
                    if (uriInfo.leaseAmount == this.cfg.xrpl.leaseAmount) {
                        await this.#queueAction(async (submissionRefs) => {
                            submissionRefs.refs ??= [{}];
                            // Check again wether the transaction is validated before retry.
                            const txHash = submissionRefs?.refs[0]?.submissionResult?.result?.tx_json?.hash;
                            if (txHash) {
                                const txResponse = await this.hostClient.xrplApi.getTransactionValidatedResults(txHash);
                                if (txResponse && txResponse.code === "tesSUCCESS") {
                                    console.log('Transaction is validated and success, Retry skipped!')
                                    return;
                                }
                            }
                            await this.hostClient.offerMintedLease(t.index, this.cfg.xrpl.leaseAmount, { submissionRef: submissionRefs?.refs[0] });
                        });
                        console.log(`Queued lease offer ${i + 1} of ${unoffered.length}.`);
                    }
                    else {
                        console.error(`Lease amount inconsistency detected. Lease amount in lease: ${uriInfo.leaseAmount}EVR, in config: ${this.cfg.xrpl.leaseAmount}EVR`);
                        console.error(`Please re-configure the lease amount.`);
                    }
                    i++;
                }
            }
            console.log("Unoffered lease check completed.");
        }
        catch (e) {
            console.log("Error occurred in unoffered lease check.", e);
        }

    }

    // Expire leases
    async #expireInstances() {
        const currentTime = evernode.UtilHelpers.getCurrentUnixTime();

        // Filter out instances which needed to be expired and destroy them.
        const expired = this.expiryList.filter(x => x.expiryTimestamp < currentTime);
        if (expired && expired.length) {
            console.log(`Starting the expiring instances job...`);
            this.#instanceExpirationQueue.push(...expired);
            this.expiryList = this.expiryList.filter(x => x.expiryTimestamp >= currentTime);
        }

        if (!this.#xrplHalted && this.#instanceExpirationQueue.length) {
            this.db.open();
            await this.#acquireLeaseUpdateLock();
            for (let item of this.#instanceExpirationQueue) {
                try {
                    if (!this.#xrplHalted) {
                        await this.#expireInstance(item, currentTime);
                        // Remove from the queue
                        this.#instanceExpirationQueue = this.#instanceExpirationQueue.filter(i => i.containerName != item.containerName);
                    }
                    else {
                        console.log("XRPL is halted.")
                        break;
                    }
                }
                catch (e) {
                    console.log(`Error "${e}", occurred in expiring the item : ${item}.`)
                }
            }
            await this.#releaseLeaseUpdateLock();
            this.db.close();
            console.log(`Stopping the expiring instances job...`);
        }
    }

    // Heartbeat sender
    async #sendHeartbeat() {
        await this.#queueAction(async (submissionRefs) => {
            submissionRefs.refs ??= [{}];
            // Check again wether the transaction is validated before retry.
            const txHash = submissionRefs?.refs[0]?.submissionResult?.result?.tx_json?.hash;
            if (txHash) {
                const txResponse = await this.hostClient.xrplApi.getTransactionValidatedResults(txHash);
                if (txResponse && txResponse.code === "tesSUCCESS") {
                    console.log('Transaction is validated and success, Retry skipped!')
                    return;
                }
            }

            let ongoingHeartbeat = false;
            const currentMoment = await this.hostClient.getMoment();

            // Sending heartbeat every CONF_HOST_HEARTBEAT_FREQ moments.
            if (!ongoingHeartbeat &&
                (this.lastHeartbeatMoment === 0 || (currentMoment % this.hostClient.config.hostHeartbeatFreq === 0 && currentMoment !== this.lastHeartbeatMoment))) {
                ongoingHeartbeat = true;
                console.log(`Reporting heartbeat at Moment ${currentMoment}...`);

                // Send heartbeat with votes, if there are votes in the config.
                let heartbeatSent = false;
                const votes = this.governanceManager.getVotes();
                if (votes) {
                    const voteArr = (await Promise.all(Object.entries(votes).map(async ([key, value]) => {
                        const candidate = await this.hostClient.getCandidateById(key);
                        // Delete candidate vote if there's no such candidate.
                        if (!candidate) {
                            this.governanceManager.clearCandidate(key);
                            return null;
                        }
                        return {
                            candidate: candidate.uniqueId,
                            vote: value === evernode.EvernodeConstants.CandidateVote.Support ?
                                evernode.EvernodeConstants.CandidateVote.Support :
                                evernode.EvernodeConstants.CandidateVote.Reject,
                            idx: candidate.index
                        };
                    }))).filter(v => v).sort((a, b) => a.idx - b.idx);
                    if (voteArr && voteArr.length) {
                        for (const vote of voteArr) {
                            try {
                                await this.hostClient.heartbeat(vote, { submissionRef: submissionRefs?.refs[0], ...this.#prepareHostClientFunctionOptions() });
                                this.lastHeartbeatMoment = await this.hostClient.getMoment();
                                heartbeatSent = true;
                            }
                            catch (e) {
                                // Remove candidate from config in vote validation from the hook failed.
                                if (e.code === 'VOTE_VALIDATION_ERR') {
                                    console.error(e.error);
                                    this.governanceManager.clearCandidate(vote.candidate);
                                }
                                else {
                                    console.error("Heartbeat tx with vote error", e);
                                    throw e;
                                }
                            }
                        }
                    }
                }

                // Return if at-least one heartbeat has been sent. Otherwise send heartbeat without votes.
                if (heartbeatSent)
                    return;

                try {
                    await this.hostClient.heartbeat({}, { submissionRef: submissionRefs?.refs[0], ...this.#prepareHostClientFunctionOptions() });
                    this.lastHeartbeatMoment = await this.hostClient.getMoment();
                }
                catch (err) {
                    if (err.code === 'tecHOOK_REJECTED') {
                        console.log("Heartbeat rejected by the hook.");
                    }
                    else {
                        console.log("Heartbeat tx error", err);
                    }
                    throw err;
                }
                finally {
                    ongoingHeartbeat = false;
                }
            }
        }, this.#heartbeatRetryCount, this.#heartbeatRetryDelay);
    }

    async #expireInstance(lease, currentTime = evernode.UtilHelpers.getCurrentUnixTime()) {
        try {
            if (currentTime >= lease.expiryTimestamp)
                console.log(`Moments exceeded (current timestamp:${currentTime}, expiry timestamp:${lease.expiryTimestamp}). Destroying ${lease.containerName}`);
            else
                console.log(`Terminate received (current timestamp:${currentTime}, expiry timestamp:${lease.expiryTimestamp}). Destroying ${lease.containerName}`);
            // Expire the current lease agreement (Burn the instance URIToken) and re-minting and creating sell offer for the same lease index.
            const uriToken = (await this.hostClient.getLeaseByIndex(lease.containerName));
            // If there's no uriToken for this record it should be already burned and instance is destroyed, So we only delete the record.
            if (!uriToken)
                console.log(`Cannot find an URIToken for ${lease.containerName}`);
            else {
                const uriInfo = evernode.UtilHelpers.decodeLeaseTokenUri(uriToken.URI);
                await this.destroyInstance(lease.containerName, uriInfo.leaseIndex, uriInfo?.outboundIP?.address);
            }

            this.activeInstanceCount--;
            /**
             * Soft deletion for debugging purpose.
             */
            // await this.updateLeaseStatus(x.txHash, LeaseStatus.EXPIRED);


            // Remove from the queue
            this.#instanceExpirationQueue = this.#instanceExpirationQueue.filter(i => i.containerName != lease.containerName);

            await this.#queueAction(async (submissionRefs) => {
                submissionRefs.refs ??= [{}];
                // Check again whether the transaction is validated before retry.
                const txHash = submissionRefs?.refs[0]?.submissionResult?.result?.tx_json?.hash;
                if (txHash) {
                    const txResponse = await this.hostClient.xrplApi.getTransactionValidatedResults(txHash);
                    if (txResponse && txResponse.code === "tesSUCCESS") {
                        console.log('Transaction is validated and success, Retry skipped!')
                        return;
                    }
                }
                // Update the registry with the active instance count.
                await this.hostClient.updateRegInfo(this.activeInstanceCount, null, null, null, null, null, null, null, null, null, null, { submissionRef: submissionRefs?.refs[0] });
                console.log(`${lease.containerName} queued for token expiry.`)
            });

        }
        catch (e) {
            console.error(e);
        }
    }

    // Connect the host and trying to reconnect in the event of account not found error.
    // Account not found error can be because of a network reset. (Dev and test nets)
    async #connect(client, options = null) {
        let attempts = 0;
        // eslint-disable-next-line no-constant-condition
        while (true) {
            try {
                attempts++;
                const ret = options ? await client.connect(options) : await client.connect();
                if (ret)
                    break;
            } catch (error) {
                if (error?.data?.error === 'actNotFound') {
                    let delaySec;
                    // The maximum delay will be 5 minutes.
                    if (attempts > 150) {
                        delaySec = 300;
                    } else {
                        delaySec = 2 * attempts;
                    }
                    console.log(`Network reset detected. Attempt ${attempts} failed. Retrying in ${delaySec}s...`);
                    await new Promise(resolve => setTimeout(resolve, delaySec * 1000));
                } else
                    throw error;
            }
        }
    }

    async #connectHost() {
        await this.#connect(this.hostClient, { reputationAddress: this.cfg.xrpl.reputationAddress, reputationSecret: this.cfg.xrpl.reputationSecret });
    }

    async #connectRegistry(options = {}) {
        await this.#connect(this.regClient, options);
    }

    #startPruneScheduler() {
        const timeout = appenv.ORPHAN_PRUNE_SCHEDULER_INTERVAL_HOURS * 3600000; // Hours to millisecs.

        const scheduler = async (isStartup = false) => {
            console.log(`Starting the scheduled prune job...`);
            await this.#acquireLeaseUpdateLock();
            await this.#pruneOrphanLeases(isStartup).catch(console.error).finally(async () => {
                await this.#releaseLeaseUpdateLock();
            });
            console.log(`Ended the scheduled prune job.`);
            setTimeout(async () => {
                await scheduler();
            }, timeout);
        };

        setTimeout(async () => {
            await scheduler(true);
        }, 0);
    }

    #startSashimonoClockScheduler() {
        const timeout = appenv.SASHIMONO_SCHEDULER_INTERVAL_SECONDS * 1000; // Seconds to millisecs.

        const scheduler = async () => {
            this.#checkLedgersForHalt();
            await this.#expireInstances();
            await this.#processConcurrencyQueue();
            setTimeout(async () => {
                await scheduler();
            }, timeout);
        };

        setTimeout(async () => {
            await scheduler();
        }, timeout);
    }

    async #startHeartBeatScheduler() {
        const momentSize = this.hostClient.config.momentSize;
        const halfMomentSize = momentSize / 2; // Getting 50% of moment size
        const acceptanceLimit = Math.floor(momentSize * 0.75); // Getting 75% of moment size

        const timeout = momentSize * 1000; // Converting seconds to milliseconds.

        const scheduler = async () => {
            setTimeout(async () => {
                await scheduler();
            }, timeout);
            await this.#sendHeartbeat();
        };

        const currentTimestamp = evernode.UtilHelpers.getCurrentUnixTime();
        const currentMomentStartIdx = await this.hostClient.getMomentStartIndex();
        const currentMoment = await this.hostClient.getMoment();
        const currentMomentDuration = currentTimestamp - currentMomentStartIdx;
        const hostInfo = await this.hostClient.getRegistration();

        // Schedule the next heartbeat based on last heartbeat occurrence.
        // NOTE : Initially checks whether host has sent a heartbeat in the current moment or not.
        // If it's true, then schedule the next heartbeat based on its last heartbeat.
        // If not, further check whether it is about to send a heartbeat at the which state of a moment.
        // If the current timestamp lies in the last quarter of the moment, then schedule the next heartbeat randomly within the first 75% of the next moment.
        // If not, schedule it randomly within the first 75% of the current moment.
        let schedule = 0;
        if (this.lastHeartbeatMoment !== currentMoment) {
            const buffer = Buffer.from(hostInfo.uriTokenId.slice(-4), 'hex');
            const randomValue = buffer.readUInt16BE(0);
            const momentRemainder = momentSize - currentMomentDuration;
            schedule = Math.floor((randomValue / 0xFFFF) * acceptanceLimit) + momentRemainder;

            if (currentMomentDuration <= acceptanceLimit) {
                const maxDelay = acceptanceLimit - currentMomentDuration;
                const currentHeartbeatSchedule = Math.floor((randomValue / 0xFFFF) * maxDelay);
                let sendDuration = currentMomentDuration + currentHeartbeatSchedule;
                const currentHeartbeatTimeout = (sendDuration < halfMomentSize) ? ((currentHeartbeatSchedule + 60) * 1000) : (currentHeartbeatSchedule * 1000);
                console.log(`This moment's heartbeat is scheduled to be sent in ${currentHeartbeatTimeout} milliseconds.`);

                setTimeout(async () => {
                    await this.#sendHeartbeat();
                }, currentHeartbeatTimeout);
            }
        } else {
            schedule = momentSize - (currentTimestamp - hostInfo.lastHeartbeatIndex);
        }

        // If the start index is in the beginning of the moment, delay the heartbeat scheduler 1 minute to make sure the hook timestamp is not in previous moment when accepting the heartbeat.
        let sendDuration = currentMomentDuration + schedule;
        const startTimeout = ((sendDuration <= momentSize) ? sendDuration < halfMomentSize : sendDuration - momentSize < halfMomentSize)
            ? ((schedule + 60) * 1000) : (schedule * 1000);
        console.log(`Heartbeat Scheduler scheduled to start in ${startTimeout} milliseconds.`);

        setTimeout(async () => {
            await scheduler();
        }, startTimeout);
    }

    // Try to acquire the lease update lock.
    async #acquireLeaseUpdateLock() {
        await new Promise(async resolve => {
            while (this.#leaseUpdateLock) {
                await new Promise(resolveSleep => {
                    setTimeout(resolveSleep, 1000);
                })
            }
            resolve();
        });
        this.#leaseUpdateLock = true;
    }

    // Release the lease update lock.
    async #releaseLeaseUpdateLock() {
        this.#leaseUpdateLock = false;
    }

    async #pruneOrphanLeases(isStartup = false) {
        // Note: If this is soft deletion we need to handle the destroyed status and replace deleteLeaseRecord with changing the status.

        // Get the records which are created before an acquire timeout x 2.
        // leaseAcqureWindow is in seconds.
        const timeoutSecs = (this.hostClient.config.leaseAcquireWindow * appenv.ACQUIRE_LEASE_TIMEOUT_THRESHOLD) * 2;
        const timeMargin = new Date(Date.now() - (1000 * timeoutSecs));

        this.sashiDb.open();
        const instances = (await this.sashiDb.getValues(this.sashiTable));
        this.sashiDb.close();
        this.db.open();
        const leases = (await this.getLeaseRecords());
        this.db.close();

        let activeInstanceCount = leases.filter(r => (r.status === LeaseStatus.ACQUIRED || r.status === LeaseStatus.EXTENDED)).length;

        // Remove the instances which are orphan.
        // Only consider the older ones.
        for (const instance of instances.filter(i => (isStartup || i.time < timeMargin))) {
            try {
                const leaseIndex = leases.findIndex(l => l.container_name === instance.name);
                const lease = leaseIndex >= 0 ? leases[leaseIndex] : null;
                // If there's a lease record this is created from message board. Else this is created without obtaining a lease or this is a ghost instance.
                if (lease) {
                    leases.splice(leaseIndex, 1);
                    const uriToken = (await this.hostClient.getLeaseByIndex(instance.name));

                    // If lease is in ACQUIRING status acquire response is not received by the tenant and lease is not in expiry list.
                    // If lease is in DESTROYED leases are handled but instance is not destroyed.
                    // If the URIToken is still owned by the host we destroy the instance since this is not a valid lease.
                    // In these cases, destroy the instance.
                    if ((lease.status === LeaseStatus.ACQUIRING || lease.status === LeaseStatus.DESTROYED) || !uriToken || uriToken.Owner === this.hostClient.xrplAcc.address) {
                        console.log(`Pruning orphan instance with lease ${instance.name}...`);
                        await this.sashiCli.destroyInstance(instance.name);
                        this.db.open();
                        let leaseTxHash = await this.getLeaseTxHash(instance.name);
                        await this.updateLeaseStatus(leaseTxHash, LeaseStatus.DESTROYED);
                        this.db.close();

                        // After destroying, If the URIToken is owned by the tenant, burn the URIToken and recreate and refund the tenant.
                        if (uriToken && uriToken.Owner != this.hostClient.xrplAcc.address) {
                            const uriInfo = evernode.UtilHelpers.decodeLeaseTokenUri(uriToken.URI);
                            await this.recreateLeaseOffer(instance.name, uriInfo.leaseIndex, uriInfo.outboundIP?.address);
                            await this.#queueAction(async (submissionRefs) => {
                                submissionRefs.refs ??= [{}];
                                // Check again wether the transaction is validated before retry.
                                const txHash = submissionRefs?.refs[0]?.submissionResult?.result?.tx_json?.hash;
                                if (txHash) {
                                    const txResponse = await this.hostClient.xrplApi.getTransactionValidatedResults(txHash);
                                    if (txResponse && txResponse.code === "tesSUCCESS") {
                                        console.log('Transaction is validated and success, Retry skipped!')
                                        return;
                                    }
                                }
                                console.log(`Refunding tenant ${uriToken.Owner}...`);
                                await this.hostClient.refundTenant(lease.tx_hash, uriToken.Owner, uriInfo.leaseAmount.toString(), { submissionRef: submissionRefs?.refs[0] });
                            });
                        }
                        else {
                            // Remove the lease record.
                            this.db.open();
                            await this.deleteLeaseRecord(lease.tx_hash);
                            this.db.close();
                        }

                        if (lease.status === LeaseStatus.ACQUIRED || lease.status === LeaseStatus.EXTENDED)
                            activeInstanceCount--;
                    }
                }
                else if (LEASE_ID_REG_EXP.test(instance.name)) {
                    // If the instance does not have lease record, This should be already pruned by lease prune job.
                    // So we destroy the instance.
                    console.log(`Pruning orphan instance without lease ${instance.name}...`);
                    await this.sashiCli.destroyInstance(instance.name);
                }
            }
            catch (e) {
                console.error(e);
            }
        }

        // Remove the leases which are orphan (Does not have an instance).
        // Only consider the older ones.
        // If this is prune call at the startup and there are acquiring records, they won't be handled since there's no data for them in the memory.
        // Since above do not have timestamp we do not consider time margin, we just prune them.
        for (const lease of leases.filter(l => l.status === LeaseStatus.DESTROYED || l.status === LeaseStatus.BURNED || (((isStartup && l.status === LeaseStatus.ACQUIRING) || l.timestamp < timeMargin) &&
            (l.status === LeaseStatus.ACQUIRING || l.status === LeaseStatus.ACQUIRED || l.status === LeaseStatus.EXTENDED)))) {
            try {
                // If lease does not have an instance.
                this.sashiDb.open();
                const instances = (await this.sashiDb.getValues(this.sashiTable, { name: lease.container_name }));
                this.sashiDb.close();

                if (!instances || instances.length === 0) {
                    console.log(`Pruning orphan lease ${lease.container_name}...`);
                    if (lease.status !== LeaseStatus.BURNED) {
                        this.db.open();
                        let leaseTxHash = await this.getLeaseTxHash(lease.container_name);
                        await this.updateLeaseStatus(leaseTxHash, LeaseStatus.DESTROYED);
                        this.db.close();
                    }

                    const uriToken = (await this.hostClient.getLeaseByIndex(lease.container_name));
                    if (uriToken && uriToken.Owner != this.hostClient.xrplAcc.address) {
                        const uriInfo = evernode.UtilHelpers.decodeLeaseTokenUri(uriToken.URI);
                        await this.recreateLeaseOffer(lease.container_name, uriInfo.leaseIndex, uriInfo.outboundIP?.address);

                        await this.#queueAction(async (submissionRefs) => {
                            submissionRefs.refs ??= [{}];
                            // Check again wether the transaction is validated before retry.
                            const txHash = submissionRefs?.refs[0]?.submissionResult?.result?.tx_json?.hash;
                            if (txHash) {
                                const txResponse = await this.hostClient.xrplApi.getTransactionValidatedResults(txHash);
                                if (txResponse && txResponse.code === "tesSUCCESS") {
                                    console.log('Transaction is validated and success, Retry skipped!')
                                    return;
                                }
                            }
                            // If lease is in ACQUIRING status acquire response is not received by the tenant and lease is not in expiry list.
                            if (lease.status === LeaseStatus.ACQUIRING) {
                                console.log(`Refunding tenant ${uriToken.Owner}...`);
                                await this.hostClient.refundTenant(lease.tx_hash, uriToken.Owner, uriInfo.leaseAmount.toString(), { submissionRef: submissionRefs?.refs[0] });
                            }
                        });
                    }
                    else {
                        // Remove the lease record.
                        this.db.open();
                        await this.deleteLeaseRecord(lease.tx_hash);
                        this.db.close();
                    }


                    if (lease.status === LeaseStatus.ACQUIRED || lease.status === LeaseStatus.EXTENDED)
                        activeInstanceCount--;
                }
            }
            catch (e) {
                console.error(e);
            }
        }

        await this.#queueAction(async (submissionRefs) => {
            submissionRefs.refs ??= [{}];
            // Check again wether the transaction is validated before retry.
            const txHash = submissionRefs?.refs[0]?.submissionResult?.result?.tx_json?.hash;
            if (txHash) {
                const txResponse = await this.hostClient.xrplApi.getTransactionValidatedResults(txHash);
                if (txResponse && txResponse.code === "tesSUCCESS") {
                    console.log('Transaction is validated and success, Retry skipped!')
                    return;
                }
            }
            // If active instance count is updated, Send the update registration transaction.
            if (this.activeInstanceCount !== activeInstanceCount) {
                this.activeInstanceCount = activeInstanceCount;
                await this.hostClient.updateRegInfo(this.activeInstanceCount, null, null, null, null, null, null, null, null, null, null, { submissionRef: submissionRefs?.refs[0] });
            }
        });
    }

    async #catchupMissedLeases() {
        console.log("Start catching up missed leases");
        const fullHistoryXrplApi = new evernode.XrplApi();

        this.db.open();
        const leases = (await this.db.getValues(this.leaseTable));
        this.db.close();

        try {
            await fullHistoryXrplApi.connect();
            const lastWatchedLedger = await this.db.getValues(this.utilTable, { name: appenv.LAST_WATCHED_LEDGER });
            if (lastWatchedLedger && lastWatchedLedger[0]?.value != "NULL") {
                const hostAccount = await new evernode.XrplAccount(this.cfg.xrpl.address, this.cfg.xrpl.secret, { xrplApi: fullHistoryXrplApi });
                const transactionHistory = await hostAccount.getAccountTrx(lastWatchedLedger[0].value, -1);

                const transactions = transactionHistory.map((record) => {
                    const transaction = record.tx;
                    transaction.Memos = evernode.TransactionHelper.deserializeMemos(transaction.Memos);
                    transaction.HookParameters = evernode.TransactionHelper.deserializeHookParams(transaction.HookParameters);
                    return transaction;
                });

                loop1:
                for (const trx of transactions) {
                    try {
                        const paramValues = trx.HookParameters.map(p => p.value);
                        if (paramValues.includes(evernode.EventTypes.ACQUIRE_LEASE) || paramValues.includes(evernode.EventTypes.EXTEND_LEASE) || paramValues.includes(evernode.EventTypes.TERMINATE_LEASE)) {
                            // Update last watched ledger sequence number.
                            await this.updateLastIndexRecord(trx.ledger_index);

                            // Avoid re-refunding possibility.
                            if (trx.ledger_index === lastWatchedLedger[0]?.value) {

                                for (const tx of transactions) {
                                    // Skip, if this transaction was previously considered.
                                    const acquireSucRef = this.#getTrxHookParams(tx, evernode.EventTypes.ACQUIRE_SUCCESS);
                                    if (acquireSucRef === trx.hash)
                                        continue loop1;

                                    const acquireErrRef = this.#getTrxHookParams(tx, evernode.EventTypes.ACQUIRE_ERROR);
                                    if (acquireErrRef === trx.hash)
                                        continue loop1;

                                    const extendSucRef = this.#getTrxHookParams(tx, evernode.EventTypes.EXTEND_SUCCESS);
                                    if (extendSucRef === trx.hash)
                                        continue loop1;

                                    const extendErrRef = this.#getTrxHookParams(tx, evernode.EventTypes.EXTEND_ERROR);
                                    if (extendErrRef === trx.hash)
                                        continue loop1;

                                    const refundRef = this.#getTrxHookParams(tx, evernode.EventTypes.REFUND);
                                    if (refundRef === trx.hash)
                                        continue loop1;
                                }
                            }

                            trx.Destination = this.cfg.xrpl.address;

                            // Handle Acquires.
                            if (paramValues.includes(evernode.EventTypes.ACQUIRE_LEASE)) {

                                // Find and bind the bought lease offer (If the trx. is  an ACQUIRE, it should be an URITokenBuy trx)
                                const offer = (await hostAccount.getURITokens({ ledger_index: trx.ledger_index - 1 }))?.find(o => o.index === trx?.URITokenID && o.Amount);
                                if (!trx.URITokenSellOffer)
                                    trx.URITokenSellOffer = offer;

                                const eventInfo = await this.hostClient.extractEvernodeEvent(trx);

                                // If there are leases, They are handled by prune job.
                                const lease = leases.find(l => l.container_name === eventInfo.data.uriTokenId);

                                if (!lease) {
                                    const uriToken = (await this.hostClient.getLeaseByIndex(eventInfo.data.uriTokenId));
                                    if (uriToken && uriToken.Owner != this.hostClient.xrplAcc.address) {
                                        const uriInfo = evernode.UtilHelpers.decodeLeaseTokenUri(uriToken.URI);
                                        // Have to recreate the URIToken Offer for the lease as previous one was not utilized.
                                        await this.recreateLeaseOffer(eventInfo.data.uriTokenId, uriInfo.leaseIndex, uriInfo.outboundIP?.address, true);

                                        await this.#queueAction(async (submissionRefs) => {
                                            submissionRefs.refs ??= [{}];
                                            // Check again wether the transaction is validated before retry.
                                            const txHash = submissionRefs?.refs[0]?.submissionResult?.result?.tx_json?.hash;
                                            if (txHash) {
                                                const txResponse = await this.hostClient.xrplApi.getTransactionValidatedResults(txHash);
                                                if (txResponse && txResponse.code === "tesSUCCESS") {
                                                    console.log('Transaction is validated and success, Retry skipped!')
                                                    return;
                                                }
                                            }
                                            console.log(`Refunding tenant ${eventInfo.data.tenant} for acquire...`);
                                            await this.hostClient.refundTenant(trx.hash, eventInfo.data.tenant, uriInfo.leaseAmount.toString(), { submissionRef: submissionRefs?.refs[0] });
                                        });
                                    }
                                }

                            } else if (paramValues.includes(evernode.EventTypes.EXTEND_LEASE)) { // Handle Extensions.

                                const eventInfo = await this.hostClient.extractEvernodeEvent(trx);

                                const lease = leases.find(l => l.container_name === eventInfo.data.uriTokenId && (l.status === LeaseStatus.ACQUIRED || l.status === LeaseStatus.EXTENDED));

                                if (lease) {
                                    const uriToken = (await this.hostClient.getLeaseByIndex(eventInfo.data.uriTokenId));
                                    if (uriToken && uriToken.Owner != this.hostClient.xrplAcc.address) {
                                        await this.#queueAction(async (submissionRefs) => {
                                            submissionRefs.refs ??= [{}];
                                            // Check again wether the transaction is validated before retry.
                                            const txHash = submissionRefs?.refs[0]?.submissionResult?.result?.tx_json?.hash;
                                            if (txHash) {
                                                const txResponse = await this.hostClient.xrplApi.getTransactionValidatedResults(txHash);
                                                if (txResponse && txResponse.code === "tesSUCCESS") {
                                                    console.log('Transaction is validated and success, Retry skipped!')
                                                    return;
                                                }
                                            }
                                            // The refund for the extension, if tenant still own the URIToken.
                                            console.log(`Refunding tenant ${eventInfo.data.tenant} for extend...`);
                                            await this.hostClient.refundTenant(trx.hash, eventInfo.data.tenant, eventInfo.data.payment.toString(), { submissionRef: submissionRefs?.refs[0] });
                                        });
                                    } else {
                                        console.log(`No such URIToken (${eventInfo.data.uriTokenId}) was found.`);
                                    }
                                } else {
                                    console.log(`No lease was found: (URIToken : ${eventInfo.data.uriTokenId}).`);
                                }
                            } else if (paramValues.includes(evernode.EventTypes.TERMINATE_LEASE)) { // Handle Terminates.

                                const eventInfo = await this.hostClient.extractEvernodeEvent(trx);

                                if (eventInfo.data.transaction.Destination === this.cfg.xrpl.address) {
                                    const hostingToken = await this.hostClient.getLeaseByIndex(eventInfo.data.uriTokenId);

                                    if (hostingToken && hostingToken.Owner === eventInfo.data.tenant) {
                                        const lease = leases.find(l => l.container_name === eventInfo.data.uriTokenId && (l.status === LeaseStatus.ACQUIRED || l.status === LeaseStatus.EXTENDED));

                                        if (lease) {
                                            console.log(`Received terminate lease from ${eventInfo.data.tenant}`);

                                            const item = this.expiryList.find(i => i.containerName === lease.container_name);
                                            if (item) {
                                                this.removeFromExpiryList(lease.container_name);
                                                await this.#expireInstance(item);
                                                console.log(`Terminated instance ${lease.container_name}`);
                                            }
                                            else {
                                                console.log(`Instance ${lease.container_name} is not included in expiry list.`)
                                            }
                                        }
                                        else {
                                            const uriInfo = evernode.UtilHelpers.decodeLeaseTokenUri(hostingToken.URI);
                                            await this.#queueAction(async (submissionRefs) => {
                                                submissionRefs.refs ??= [{}];
                                                // Check again wether the transaction is validated before retry.
                                                const txHash = submissionRefs?.refs[0]?.submissionResult?.result?.tx_json?.hash;
                                                if (txHash) {
                                                    const txResponse = await this.hostClient.xrplApi.getTransactionValidatedResults(txHash);
                                                    if (txResponse && txResponse.code === "tesSUCCESS") {
                                                        console.log('Transaction is validated and success, Retry skipped!')
                                                        return;
                                                    }
                                                }
                                                console.log(`Expire the terminated instance ${hostingToken.index} lease.`);
                                                await this.hostClient.expireLease(hostingToken.index, { submissionRef: submissionRefs?.refs[0] });
                                            });


                                            await this.#queueAction(async (submissionRefs) => {
                                                submissionRefs.refs ??= [{}];
                                                // Check again wether the transaction is validated before retry.
                                                const txHash = submissionRefs?.refs[0]?.submissionResult?.result?.tx_json?.hash;
                                                if (txHash) {
                                                    const txResponse = await this.hostClient.xrplApi.getTransactionValidatedResults(txHash);
                                                    if (txResponse && txResponse.code === "tesSUCCESS") {
                                                        console.log('Transaction is validated and success, Retry skipped!')
                                                        return;
                                                    }
                                                }
                                                console.log(`Re-created lease offer for the terminated instance ${hostingToken.index}.`);
                                                await this.hostClient.offerLease(uriInfo.leaseIndex,
                                                    uriInfo.leaseAmount,
                                                    appenv.TOS_HASH,
                                                    uriInfo.outboundIP, { submissionRef: submissionRefs?.refs[0] });
                                            });
                                        }
                                    }
                                    else {
                                        console.log("The URIToken ownership verification was failed in the lease termination process");
                                    }
                                }
                            }
                        }
                    } catch (e) {
                        console.error(e);
                    }
                }
            }
        } catch (e) {
            console.error(e);
        } finally {
            await fullHistoryXrplApi.disconnect();
        }

        console.log("End catching up missed leases");
    }

    #getTrxHookParams(txn, paramName) {
        const hookParams = txn.HookParameters;

        if (hookParams.length > 1 && hookParams[0]?.value == paramName)
            return hookParams[1]?.value

        return null;
    }

    async recreateLeaseOffer(uriTokenId, leaseIndex, outboundIP, noLeaseRecord = false) {
        await this.#queueAction(async (submissionRefs) => {
            submissionRefs.refs ??= [{}, {}];
            // Check again whether the transaction is validated before retry.
            const txHash1 = submissionRefs?.refs[0]?.submissionResult?.result?.tx_json?.hash;
            let retry = true;
            if (txHash1) {
                const txResponse = await this.hostClient.xrplApi.getTransactionValidatedResults(txHash1);
                if (txResponse && txResponse.code === "tesSUCCESS") {
                    console.log('Transaction is validated and success, Retry skipped!');
                    retry = false;
                }
            }

            this.db.open();
            const leaseTxHash = await this.getLeaseTxHash(uriTokenId);
            const status = await this.getLeaseStatus(leaseTxHash);
            if (retry && (noLeaseRecord || status === LeaseStatus.DESTROYED || status === LeaseStatus.FAILED || status === LeaseStatus.SASHI_TIMEOUT)) {
                // Burn the URIToken and recreate the offer.
                await this.hostClient.expireLease(uriTokenId, { submissionRef: submissionRefs?.refs[0] });
                if (!noLeaseRecord)
                    await this.updateLeaseStatus(leaseTxHash, LeaseStatus.BURNED);
            }
            this.db.close();

            // We refresh the config here, So if the purchaserTargetPrice is updated by the purchaser service, the new value will be taken.
            await this.hostClient.refreshConfig();

            // Check again wether the transaction is validated before retry.
            const txHash2 = submissionRefs?.refs[1]?.submissionResult?.result?.tx_json?.hash;
            retry = true;
            if (txHash2) {
                const txResponse = await this.hostClient.xrplApi.getTransactionValidatedResults(txHash2);
                if (txResponse && txResponse.code === "tesSUCCESS") {
                    console.log('Transaction is validated and success, Retry skipped!')
                    retry = false;
                }
            }
            this.db.open();
            if (retry && (noLeaseRecord || await this.getLeaseStatus(leaseTxHash) == LeaseStatus.BURNED)) {
                const leaseAmount = this.cfg.xrpl.leaseAmount ? this.cfg.xrpl.leaseAmount : parseFloat(this.hostClient.config.purchaserTargetPrice);
                // Don't send submission refs because there're two transactions here.
                await this.hostClient.offerLease(leaseIndex, leaseAmount, appenv.TOS_HASH, outboundIP);
                //Delete the lease record related to this instance (Permanent Delete).
                if (!noLeaseRecord)
                    await this.deleteLeaseRecord(leaseTxHash);
                console.log(`Destroyed ${uriTokenId}.`);
            }
            this.db.close();
        });
    }

    async handleAcquireLease(r) {

        const acquireRefId = r.acquireRefId; // Acquire tx hash.
        const uriTokenId = r.uriTokenId;
        const leaseAmount = parseFloat(r.leaseAmount);
        const tenantAddress = r.tenant;
        let requestValidated = false;
        let createRes;
        let leaseIndex = -1; // Lease index cannot be negative, So we keep initial non populated value as -1.
        let instanceOutboundIPAddress = null;


        this.db.open();

        try {
            await this.#acquireLeaseUpdateLock();

            if (r.host !== this.cfg.xrpl.address)
                throw "Invalid host in the lease aquire.";

            // Update last watched ledger sequence number.
            await this.updateLastIndexRecord(r.transaction.LedgerIndex);

            // Get the existing uriToken of the lease.

            const uriToken = (await this.hostClient.getLeaseByIndex(uriTokenId));
            if (!uriToken || uriToken.Owner !== tenantAddress)
                throw "Could not find the uriToken for lease acquire request.";

            const uriInfo = evernode.UtilHelpers.decodeLeaseTokenUri(uriToken.URI);
            instanceOutboundIPAddress = uriInfo?.outboundIP?.address;

            if (leaseAmount != uriInfo.leaseAmount)
                throw 'URIToken embedded lease amount and acquire lease amount does not match.';
            leaseIndex = uriInfo.leaseIndex;

            // Since acquire is accepted for leaseAmount
            const moments = 1;

            // Use URITokenID as the instance name.
            const containerName = uriTokenId;
            console.log(`Received acquire lease from ${tenantAddress}`);
            requestValidated = true;
            await this.createLeaseRecord(acquireRefId, tenantAddress, containerName, moments);

            // The last validated ledger when we receive the acquire request.
            const startingValidatedTime = evernode.UtilHelpers.getCurrentUnixTime();

            // Wait until the sashi cli is available.
            await this.sashiCli.wait();

            // Number of validated ledgers passed while processing the last request.
            let diff = evernode.UtilHelpers.getCurrentUnixTime() - startingValidatedTime;
            // Give-up the acquiring process if processing the last request takes more than 40% of allowed window(Window is in seconds).
            let threshold = this.hostClient.config.leaseAcquireWindow * appenv.ACQUIRE_LEASE_WAIT_TIMEOUT_THRESHOLD;
            if (diff > threshold) {
                console.error(`Sashimono busy timeout. Took: ${diff} seconds. Threshold: ${threshold} seconds`);
                // Update the lease status of the request to 'SashiTimeout'.
                await this.updateLeaseStatus(acquireRefId, LeaseStatus.SASHI_TIMEOUT);
                await this.recreateLeaseOffer(uriTokenId, leaseIndex, uriInfo?.outboundIP?.address);
            }
            else {
                const instanceRequirements = { ...r.payload, outbound_ipv6: (uriInfo.outboundIP?.family == 6) ? uriInfo.outboundIP?.address : "-", outbound_net_interface: (uriInfo.outboundIP?.family == 6) ? this.cfg.networking.ipv6.interface : "-" };
                createRes = await this.sashiCli.createInstance(containerName, instanceRequirements);

                // Number of validated ledgers passed while the instance is created.
                diff = evernode.UtilHelpers.getCurrentUnixTime() - startingValidatedTime;
                // Give-up the acquiring process if the instance creation itself takes more than 80% of allowed window(in seconds).
                threshold = this.hostClient.config.leaseAcquireWindow * appenv.ACQUIRE_LEASE_TIMEOUT_THRESHOLD;
                if (diff > threshold) {
                    console.error(`Instance creation timeout. Took: ${diff} seconds. Threshold: ${threshold} seconds`);
                    // Update the lease status of the request to 'SashiTimeout'.
                    await this.updateLeaseStatus(acquireRefId, LeaseStatus.SASHI_TIMEOUT);
                    await this.destroyInstance(createRes.content.name, leaseIndex, instanceOutboundIPAddress);
                } else {
                    console.log(`Instance created for ${tenantAddress}`);

                    // Save the value to a local variable to prevent the value being updated between two calls ending up with two different values.
                    const currentLedgerIndex = this.lastValidatedLedgerIndex;

                    // Lease created Timestamp
                    const createdTimestamp = evernode.UtilHelpers.getCurrentUnixTime();

                    // Add to in-memory expiry list, so the instance will get destroyed when the moments exceed,
                    this.addToExpiryList(acquireRefId, createRes.content.name, tenantAddress, this.getExpiryTimestamp(createdTimestamp, moments));

                    // Update the active instance count.
                    this.activeInstanceCount++;
                    await this.#queueAction(async (submissionRefs) => {
                        submissionRefs.refs ??= [{}, {}];
                        // Check again wether the transaction is validated before retry.
                        const txHash1 = submissionRefs?.refs[0]?.submissionResult?.result?.tx_json?.hash;
                        let retry = true;
                        if (txHash1) {
                            const txResponse = await this.hostClient.xrplApi.getTransactionValidatedResults(txHash1);
                            if (txResponse && txResponse.code === "tesSUCCESS") {
                                console.log('Transaction is validated and success, Retry skipped!')
                                retry = false;
                            }
                        }
                        if (retry) {
                            await this.hostClient.updateRegInfo(this.activeInstanceCount, null, null, null, null, null, null, null, null, null, null, { submissionRef: submissionRefs?.refs[0] });
                        }

                        // Send the acquire response with created instance info.
                        // Modify Response.
                        // Check again wether the transaction is validated before retry.
                        const txHash2 = submissionRefs?.refs[1]?.submissionResult?.result?.tx_json?.hash;
                        retry = true;
                        if (txHash2) {
                            const txResponse = await this.hostClient.xrplApi.getTransactionValidatedResults(txHash2);
                            if (txResponse && txResponse.code === "tesSUCCESS") {
                                console.log('Transaction is validated and success, Retry skipped!')
                                retry = false;
                            }
                        }
                        if (retry) {
                            createRes.content.domain = createRes.content.ip;
                            if (uriInfo.outboundIP)
                                createRes.content.outbound_ip = uriInfo.outboundIP.address;
                            delete createRes.content.ip;
                            const options = instanceRequirements?.messageKey ? { messageKey: instanceRequirements.messageKey } : {};
                            await this.hostClient.acquireSuccess(acquireRefId, tenantAddress, createRes, { submissionRef: submissionRefs?.refs[1], ...options });

                            // Update the database for acquired record.
                            this.db.open();
                            await this.updateAcquiredRecord(acquireRefId, currentLedgerIndex, createdTimestamp);
                            this.db.close();
                        }
                    });
                }
            }
        }
        catch (e) {
            console.error(e);

            // Update the lease response for failures (Only if the request validated and ACQUIRING record is added).
            if (requestValidated)
                await this.updateLeaseStatus(acquireRefId, LeaseStatus.FAILED).catch(console.error);

            // Destroy the instance if created.
            if (createRes || e.type === 'initiate_error')
                await this.sashiCli.destroyInstance(e.content.instance_name).catch(console.error);

            // Re-create the lease offer (Only if the uriToken belongs to this request has a lease index).
            if (leaseIndex >= 0)
                await this.recreateLeaseOffer(uriTokenId, leaseIndex, instanceOutboundIPAddress).catch(console.error);

            await this.#queueAction(async (submissionRefs) => {
                submissionRefs.refs ??= [{}];
                // Check again wether the transaction is validated before retry.
                const txHash = submissionRefs?.refs[0]?.submissionResult?.result?.tx_json?.hash;
                if (txHash) {
                    const txResponse = await this.hostClient.xrplApi.getTransactionValidatedResults(txHash);
                    if (txResponse && txResponse.code === "tesSUCCESS") {
                        console.log('Transaction is validated and success, Retry skipped!')
                        return;
                    }
                }
                // Send error transaction with received leaseAmount.
                await this.hostClient.acquireError(acquireRefId, tenantAddress, leaseAmount, e.content || 'invalid_acquire_lease', { submissionRef: submissionRefs?.refs[0] }).catch(console.error);
            });
        }
        finally {
            await this.#releaseLeaseUpdateLock();
            this.db.close();
        }
    }

    async destroyInstance(containerName, leaseIndex, outboundIP = null) {
        // Destroy the instance.
        await this.sashiCli.destroyInstance(containerName);
        let leaseTxHash = await this.getLeaseTxHash(containerName);
        await this.updateLeaseStatus(leaseTxHash, LeaseStatus.DESTROYED);
        await this.recreateLeaseOffer(containerName, leaseIndex, outboundIP);
    }

    async handleExtendLease(r) {

        this.db.open();

        const extendRefId = r.extendRefId;
        const uriTokenId = r.uriTokenId;
        const tenantAddress = r.tenant;
        const amount = r.payment;

        try {

            if (r.transaction.Destination !== this.cfg.xrpl.address)
                throw "Invalid destination";

            const hostingToken = await this.hostClient.getLeaseByIndex(uriTokenId);

            // Update last watched ledger sequence number.
            await this.updateLastIndexRecord(r.transaction.LedgerIndex);

            if (!hostingToken || hostingToken.Owner !== tenantAddress)
                throw "The URIToken ownership verification was failed in the lease extension process";

            const uriInfo = evernode.UtilHelpers.decodeLeaseTokenUri(hostingToken.URI);
            const leaseAmount = uriInfo.leaseAmount;
            if (leaseAmount <= 0)
                throw "Invalid per moment lease amount";

            const extendingMoments = Math.floor(amount / leaseAmount);

            if (extendingMoments < 1)
                throw "The transaction does not satisfy the minimum extendable moments";

            const instanceSearchCriteria = { container_name: hostingToken.index };

            const instance = (await this.getLeaseRecords(instanceSearchCriteria)).find(i => (i.status === LeaseStatus.ACQUIRED || i.status === LeaseStatus.EXTENDED));

            if (!instance)
                throw "No relevant instance was found to perform the lease extension";

            console.log(`Received extend lease from ${tenantAddress}`);

            let expiryItemFound = false;

            let expiryTimeStamp;
            for (const item of this.expiryList) {
                if (item.containerName === instance.container_name) {
                    item.expiryTimestamp = this.getExpiryTimestamp(item.expiryTimestamp, extendingMoments);
                    expiryTimeStamp = item.expiryTimestamp;
                    let obj = {
                        status: LeaseStatus.EXTENDED,
                        life_moments: (instance.life_moments + extendingMoments)
                    };
                    await this.updateLeaseData(instance.tx_hash, obj);
                    expiryItemFound = true;
                    break;
                }
            }

            if (!expiryItemFound)
                throw "No matching expiration record was found for the instance";

            const expiryMoment = await this.hostClient.getMoment(expiryTimeStamp)
            await this.#queueAction(async (submissionRefs) => {
                submissionRefs.refs ??= [{}];
                // Check again wether the transaction is validated before retry.
                const txHash = submissionRefs?.refs[0]?.submissionResult?.result?.tx_json?.hash;
                if (txHash) {
                    const txResponse = await this.hostClient.xrplApi.getTransactionValidatedResults(txHash);
                    if (txResponse && txResponse.code === "tesSUCCESS") {
                        console.log('Transaction is validated and success, Retry skipped!')
                        return;
                    }
                }
                // Send the extend success response
                await this.hostClient.extendSuccess(extendRefId, tenantAddress, expiryMoment, { submissionRef: submissionRefs?.refs[0] });
            });

        }
        catch (e) {
            console.error(e);
            await this.#queueAction(async (submissionRefs) => {
                submissionRefs.refs ??= [{}];
                // Check again wether the transaction is validated before retry.
                const txHash = submissionRefs?.refs[0]?.submissionResult?.result?.tx_json?.hash;
                if (txHash) {
                    const txResponse = await this.hostClient.xrplApi.getTransactionValidatedResults(txHash);
                    if (txResponse && txResponse.code === "tesSUCCESS") {
                        console.log('Transaction is validated and success, Retry skipped!')
                        return;
                    }
                }
                // Send the extend error response
                await this.hostClient.extendError(extendRefId, tenantAddress, e.content || 'invalid_extend_lease', amount, { submissionRef: submissionRefs?.refs[0] });
            });
        } finally {
            this.db.close();
        }
    }

    async handleTerminateLease(r) {
        await this.#acquireLeaseUpdateLock();
        this.db.open();

        const uriTokenId = r.uriTokenId;
        const tenantAddress = r.tenant;

        try {
            if (r.transaction.Destination !== this.cfg.xrpl.address)
                throw "Invalid destination";

            const hostingToken = await this.hostClient.getLeaseByIndex(uriTokenId);

            // Update last watched ledger sequence number.
            await this.updateLastIndexRecord(r.transaction.LedgerIndex);

            if (!hostingToken || hostingToken.Owner !== tenantAddress)
                throw "The URIToken ownership verification was failed in the lease extension process";

            const instanceSearchCriteria = { container_name: hostingToken.index };

            const instance = (await this.getLeaseRecords(instanceSearchCriteria)).find(i => (i.status === LeaseStatus.ACQUIRED || i.status === LeaseStatus.EXTENDED));

            if (!instance)
                throw "No relevant instance was found to perform the lease extension";

            console.log(`Received terminate lease from ${tenantAddress}`);

            const item = this.expiryList.find(i => i.containerName === instance.container_name);
            if (item) {
                if (!this.#xrplHalted) {
                    this.removeFromExpiryList(instance.container_name);
                    await this.#expireInstance(item);
                    console.log(`Terminated instance ${instance.container_name}`);
                }
                else {
                    console.log("XRPL is halted.")
                }
            }
            else {
                console.log(`Instance ${instance.container_name} is not included in expiry list.`)
            }
        }
        catch (e) {
            console.error(`Error occurred in terminating the instance ${uriTokenId}.`, e);
        } finally {
            await this.#releaseLeaseUpdateLock();
            this.db.close();
        }
    }

    addToExpiryList(txHash, containerName, tenant, expiryTimestamp) {
        this.expiryList.push({
            txHash: txHash,
            containerName: containerName,
            tenant: tenant,
            expiryTimestamp: expiryTimestamp
        });
        console.log(`Container ${containerName} expiry set at ${expiryTimestamp} th timestamp`);
    }

    removeFromExpiryList(containerName) {
        this.expiryList = this.expiryList.filter(i => i.containerName != containerName);
        console.log(`Container ${containerName} removed from expiry list`);
    }

    async createLeaseTableIfNotExists() {
        // Create table if not exists.
        await this.db.createTableIfNotExists(this.leaseTable, [
            { name: 'timestamp', type: DataTypes.INTEGER, notNull: true },
            { name: 'tx_hash', type: DataTypes.TEXT, primary: true, notNull: true },
            { name: 'tenant_xrp_address', type: DataTypes.TEXT, notNull: true },
            { name: 'life_moments', type: DataTypes.INTEGER, notNull: true },
            { name: 'container_name', type: DataTypes.TEXT },
            { name: 'created_on_ledger', type: DataTypes.INTEGER },
            { name: 'status', type: DataTypes.TEXT, notNull: true }
        ]);
    }

    async createUtilDataTableIfNotExists() {
        // Create table if not exists.
        await this.db.createTableIfNotExists(this.utilTable, [
            { name: 'name', type: DataTypes.TEXT, notNull: true },
            { name: 'value', type: DataTypes.INTEGER, notNull: true }
        ]);
        await this.createLastWatchedLedgerEntryIfNotExists();
    }

    async createLastWatchedLedgerEntryIfNotExists() {
        const ret = await this.db.getValues(this.utilTable, { name: appenv.LAST_WATCHED_LEDGER });
        if (ret.length === 0) {
            await this.db.insertValue(this.utilTable, { name: appenv.LAST_WATCHED_LEDGER, value: this.lastValidatedLedgerIndex });
        }
    }

    async getAcquiredRecords() {
        return (await this.db.getValues(this.leaseTable, { status: LeaseStatus.ACQUIRED }));
    }

    async getLeaseRecords(searchCriteria = null) {
        if (searchCriteria)
            return (await this.db.getValues(this.leaseTable, searchCriteria));

        return (await this.db.getValues(this.leaseTable));
    }

    async createLeaseRecord(txHash, txTenantAddress, containerName, moments) {
        await this.db.insertValue(this.leaseTable, {
            timestamp: 0,
            tx_hash: txHash,
            tenant_xrp_address: txTenantAddress,
            life_moments: moments,
            container_name: containerName,
            status: LeaseStatus.ACQUIRING
        });
    }

    async updateLastIndexRecord(ledger_idx) {
        await this.db.updateValue(this.utilTable, {
            value: ledger_idx,
        }, { name: appenv.LAST_WATCHED_LEDGER });
    }

    async updateAcquiredRecord(txHash, ledgerIndex, timestamp) {
        await this.db.updateValue(this.leaseTable, {
            created_on_ledger: ledgerIndex,
            status: LeaseStatus.ACQUIRED,
            timestamp: timestamp
        }, { tx_hash: txHash });
    }

    async updateLeaseStatus(txHash, status) {
        await this.db.updateValue(this.leaseTable, { status: status }, { tx_hash: txHash });
    }

    async getLeaseStatus(tx_hash) {
        const leaseData = await this.db.getValues(this.leaseTable, { tx_hash: tx_hash });
        return leaseData[0]?.status;
    }

    async getLeaseTxHash(container_name) {
        const leaseData = await this.db.getValues(this.leaseTable, { container_name: container_name });
        return leaseData[0]?.tx_hash;
    }

    /**
     * Sample savingData
     * Note : The keys of the object should match with the sqlite db column names
     * {
     *      status: "XXXX",
     *      life_moments: 1
     * }
     */

    async updateLeaseData(txHash, savingData = null) {
        if (savingData)
            await this.db.updateValue(this.leaseTable, savingData, { tx_hash: txHash });
    }

    async deleteLeaseRecord(txHash) {
        await this.db.deleteValues(this.leaseTable, { tx_hash: txHash });
    }

    /**
     * Calculate and return the expiring timestamp from createdTimestamp and momet count
     * @param {*} createdTimestamp Timestamp 
     * @param { integer } moments Lifespan of the instance in moments
     * @returns 
     */
    getExpiryTimestamp(createdTimestamp, moments) {
        return createdTimestamp + moments * this.hostClient.config.momentSize;
    }


    readConfig() {
        this.cfg = ConfigHelper.readConfig(this.configPath, this.reputationDConfigPath, true);
    }

    persistConfig() {
        ConfigHelper.writeConfig(this.cfg, this.configPath);
    }
}

module.exports = {
    MessageBoard
}