import fetch from "node-fetch";
import { exec } from "child_process";
import fs from "fs";
import evernode from "evernode-js-client";
import { exit } from "process";
const { UserClient, XrplAccount, XrplApi, Defaults } = evernode;

const REDEEM_AMOUNT = "12"; // 18000 Moments ~ 60days
const PEER_SUBSET_SIZE = 5;

const configFile = "config.json";
const config = JSON.parse(fs.readFileSync(configFile));
const currentContract = config.contracts.filter(c => c.name === config.selected)[0];
if (!currentContract)
    throw "Invalid contract selected.";

const userAddr = config.xrpl.userAddress;
const userSecret = config.xrpl.userSecret;
const registryAddress = config.xrpl.registryAddress;
let xrplApi = null;
let userClient = null;
let userAcc = null;
let shouldAbort = false;
const hostAccounts = {};

async function issueRedeem(host, hostId, elem, peers, unl) {

    if (Object.keys(elem).length > 0) {
        console.log(`Instance in host ${hostId} (${host}) already created.`)
        return [true];
    }

    // Take a subset of peers based on host id. (Take last subset up to previous host)
    const subsetPeers = peers ? peers.slice(0, hostId - 1).slice(-PEER_SUBSET_SIZE) : null;

    // Copy defined config from config.json to instance requirements config.
    const config = JSON.parse(JSON.stringify(currentContract.config)) || {};
    if (unl)
        config.contract = { ...config.contract, unl: unl };
    if (subsetPeers)
        config.mesh = { ...config.mesh, known_peers: subsetPeers };

    // Redeem
    const acc = hostAccounts[host].hostAccount;
    console.log(`------Host ${hostId} (${host}): Redeeming ${acc.token}-${acc.address}...`);
    const req = {
        image: currentContract.docker.image,
        contract_id: currentContract.contract_id,
        owner_pubkey: currentContract.owner_pubkey,
        config: config
    };
    const res = await userClient.redeemSubmit(acc.token, acc.address, REDEEM_AMOUNT, req).catch(errtx => console.log(errtx));

    if (!res) {
        console.log(`Redeem issuing failed for host ${hostId}.`);
        return [false]
    }
    else {
        return [true, userClient.watchRedeemResponse(res)]
    }
}

async function processRedeemResponse(hostId, redeemOp, elem) {
    const response = await redeemOp.catch(err => console.log(`Host ${hostId} redeem error: ${err.reason}`));
    if (response && response.instance) {
        for (var k in response.instance)
            elem[k] = response.instance[k];

        console.log(`Created instance in host ${hostId}.`);
        saveConfig();
        return true;
    }
    else {
        console.log(`Instance creation failed in host ${hostId}.`);
        return false;
    }
}

async function createInstancesSequentially() {
    await createEvernodeConnections();
    await initHosts();

    let peers = null, unl = null;

    let idx = 1;
    for (const [host, elem] of Object.entries(currentContract.hosts)) {

        if (shouldAbort)
            return;

        const hostId = idx++;
        const [success, redeemOp] = await issueRedeem(host, hostId, elem, peers, unl);
        if (!success)
            return;
        if (redeemOp && !await processRedeemResponse(hostId, redeemOp, elem))
            return;

        if (!unl)
            unl = [elem.pubkey]; // Insert first instance's pubkey into all other instance's unl.

        if (!peers)
            peers = [];
        peers.push(`${host}:${elem.peer_port}`);
    }
}

async function createInstancesParallely(peerPort) {
    await createEvernodeConnections();
    await initHosts();

    // Create first instance and then create all other instances parallely assuming they all have the same peer port.

    let unl = null;
    const peers = Object.keys(currentContract.hosts).map(h => `${h}:${peerPort}`);
    const tasks = [];

    let idx = 1;
    for (const [host, elem] of Object.entries(currentContract.hosts)) {

        if (shouldAbort)
            return;

        const hostId = idx++;

        if (!unl) {
            const [success, redeemOp] = await issueRedeem(host, hostId, elem, peers, null);
            if (!success)
                return;
            if (redeemOp && !await processRedeemResponse(hostId, redeemOp, elem))
                return;

            unl = [elem.pubkey]; // Insert first instance's pubkey into all other instance's unl.
        }
        else {
            const [success, redeemOp] = await issueRedeem(host, hostId, elem, peers, unl);
            if (redeemOp)
                tasks.push(processRedeemResponse(hostId, redeemOp, elem)); // Add to parallel response watcher tasks.
        }
    }

    await Promise.all(tasks);
}

async function initHosts() {

    await userClient.prepareAccount();

    if (Object.keys(currentContract.hosts).length == 0) {
        const ips = await getVultrHosts(currentContract.vultr_group);
        ips.forEach(ip => currentContract.hosts[ip] = {});
        saveConfig();
    }

    const hosts = Object.keys(currentContract.hosts);
    console.log(`${hosts.length} hosts loaded.`);

    await Promise.all(hosts.map(host => initHostAccountData(host)))

    for (const host of hosts) {
        const { ownsTokens, hostAccount: acc } = hostAccounts[host];
        if (!ownsTokens)
            await transferHostingTokens(acc.token, acc.address, acc.secret);
    }

    console.log(`${Object.keys(hostAccounts).length} host accounts data initialized.`)
}

async function initHostAccountData(host) {
    const output = await execSsh(host, "cat /etc/sashimono/mb-xrpl/mb-xrpl.cfg");
    if (!output || output.trim() === "") {
        console.log(host, "ERROR: No output from mb-xrpl config read.")
        return;
    }

    const conf = JSON.parse(output);
    const acc = {
        address: conf.xrpl.address,
        secret: conf.xrpl.secret,
        token: conf.xrpl.token
    }

    // Check whether user owns hosting tokens already.
    console.log(`Checking user's ${acc.token} balance...`);
    const lines = await userAcc.getTrustLines(acc.token, acc.address);
    hostAccounts[host] = { ownsTokens: lines.length > 0, hostAccount: acc };
}

// Get hosting tokens from host account to user account.
async function transferHostingTokens(token, hostAddr, hostSecret) {

    console.log(`Transfering ${token} to user...`);
    const trustTx = await userAcc.setTrustLine(token, hostAddr, "9999999").catch(errtx => {
        console.log("Trust line failed.");
        console.log(errtx);
    });
    if (!trustTx)
        return false;

    const hostAcc = new XrplAccount(hostAddr, hostSecret);
    const payTx = await hostAcc.makePayment(userAddr, "9999999", token, hostAddr).catch(errtx => {
        console.log("Transfer failed.")
        console.log(errtx);
    });
    if (!payTx)
        return false;

    console.log(`Transfering of ${token} complete.`);

    return true;
}

function getVultrHosts(group) {

    return new Promise(async (resolve) => {

        if (!group || group.trim().length === 0)
            resolve([]);

        const resp = await fetch(`https://api.vultr.com/v2/instances?tag=${group}`, {
            method: 'GET',
            headers: { "Authorization": `Bearer ${config.vultr.api_key}` }
        });

        const vms = (await resp.json()).instances;
        if (!vms) {
            console.log("Failed to get vultr instances.");
            resolve([]);
            return;
        }

        const ips = vms.sort((a, b) => (a.label < b.label) ? -1 : 1).map(i => i.main_ip);
        console.log(`${ips.length} ips retrieved from Vultr.`)
        resolve(ips);
    })
}

async function createEvernodeConnections() {

    xrplApi = new XrplApi();

    Defaults.set({
        registryAddress: registryAddress,
        xrplApi: xrplApi
    })

    await xrplApi.connect();

    userClient = new UserClient(userAddr, userSecret);
    await userClient.connect();

    userAcc = new XrplAccount(userAddr, userSecret);
}

function saveConfig() {
    fs.writeFileSync(configFile, JSON.stringify(config, null, 4));
}

function execSsh(host, command) {
    return new Promise(resolve => {
        const cmd = `ssh -o StrictHostKeychecking=no root@${host} ${command}`;
        exec(cmd, (err, stdout, stderr) => {
            resolve(stdout);
        });
    })
}

async function main() {
    var args = process.argv.slice(2);

    process.on('SIGINT', () => {
        if (shouldAbort)
            exit();
        console.log('Received SIGINT. Aborting...');
        shouldAbort = true;
    });

    const mode = args[0];
    if (mode === "init") {
        await createEvernodeConnections();
        await initHosts();
    }
    else if (mode === "create") {
        if (args.length === 1) {
            await createInstancesSequentially();
        }
        else {
            console.log("Invalid args for 'create'.");
        }
    }
    else if (mode === "createall") {
        const peerPort = parseInt(args[1]);
        if (!isNaN(peerPort))
            await createInstancesParallely(peerPort);
        else
            console.log("Specify peer port for 'createall'.");
    }
    else {
        console.log("Specifiy args: init | create | createall <peerport>")
    }

    if (xrplApi)
        await xrplApi.disconnect();
}

main();