const sip = require('sip');

const targetUri = process.argv[2];
const bindPort = Number(process.argv[3]) || 3000;
const responseTimeoutMs = parsePositiveInteger(process.env.SIP_OPTIONS_TIMEOUT_MS || process.argv[4], 3000);
const maxAttempts = 2;

function parsePositiveInteger(value, fallback) {
    const parsed = Number(value);
    return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

function stopSipStack() {
    if (typeof sip.stop !== 'function') {
        return;
    }

    try {
        sip.stop();
    }
    catch (err) {
        console.log('[sip-options] error stopping local SIP stack:', err.message || err);
    }
}

let finished = false;
let responseTimeout;
let attempt = 0;
let currentCallId;

function finish(exitCode) {
    if (finished) {
        return;
    }

    finished = true;
    clearTimeout(responseTimeout);
    stopSipStack();
    process.exit(exitCode);
}

console.log('[sip-options] starting local SIP stack');
console.log('[sip-options] bind port:', bindPort);
console.log('[sip-options] target SIP URI:', targetUri || '(missing — pass as first argument)');
console.log('[sip-options] response timeout:', responseTimeoutMs + 'ms');
console.log('[sip-options] timeout retries:', maxAttempts - 1);

if (!targetUri) {
    console.log('[sip-options] exiting 2 (missing target URI)');
    process.exit(2);
}

sip.start({
    port: bindPort,
}, function (rq) {});

function rstring() { return Math.floor(Math.random()*1e6).toString(); }

function sendOptions() {
    attempt += 1;

    const fromTag = rstring();
    const callId = rstring();
    const cseqSeq = Math.floor(Math.random() * 1e5);
    currentCallId = callId;

    const r = {
        method: 'OPTIONS',
        uri: targetUri,
        headers: {
            to: { uri: 'sip:ping@dualtone' },
            from: { uri: 'sip:ping@dualtone', params: {tag: fromTag} },
            'call-id': callId,
            'User-Agent': 'Dualtone SIP Pinger',
            cseq: { method: 'OPTIONS', seq: cseqSeq },
            'content-type': 'application/sdp',
        }
    };

    if (attempt > 1) {
        console.log('[sip-options] timeout retry:', attempt + '/' + maxAttempts);
    }
    console.log('[sip-options] request method:', r.method);
    console.log('[sip-options] request URI:', r.uri);
    console.log('[sip-options] From tag:', fromTag);
    console.log('[sip-options] Call-ID:', callId);
    console.log('[sip-options] CSeq:', cseqSeq, r.headers.cseq.method);
    console.log('[sip-options] User-Agent:', r.headers['User-Agent']);
    console.log('[sip-options] sending OPTIONS and awaiting response');

    clearTimeout(responseTimeout);
    responseTimeout = setTimeout(() => {
        if (finished) {
            return;
        }

        console.log('[sip-options] timed out awaiting response');

        if (attempt < maxAttempts) {
            console.log('[sip-options] retrying OPTIONS after timeout');
            sendOptions();
            return;
        }

        console.log(`SIP OPTIONS sent to ${targetUri} - Failure: no SIP response received within ${responseTimeoutMs}ms after ${maxAttempts} attempts`);
        console.log('[sip-options] exiting 2 (timeout)');
        finish(2);
    }, responseTimeoutMs);

    sip.send(r, (response) => {
        if (finished) {
            return;
        }

        const responseCallId = response && response.headers && response.headers['call-id'];
        if (responseCallId && responseCallId !== currentCallId) {
            return;
        }

        const status = response && response.status;
        const reason = response && response.reason;
        const headerKeys = response && response.headers ? Object.keys(response.headers) : [];

        console.log('[sip-options] response received');
        console.log('[sip-options] status:', status);
        console.log('[sip-options] reason:', reason);
        if (headerKeys.length) {
            console.log('[sip-options] response header names:', headerKeys.join(', '));
        }

        if (typeof status !== 'number') {
            console.log(`SIP OPTIONS sent to ${targetUri} - Failure: SIP response did not include a numeric status`);
            console.log('[sip-options] exiting 2 (invalid response, not retrying)');
            finish(2);
        }
        else if (status >= 200 && status < 300) {
            console.log(`SIP OPTIONS sent to ${targetUri} - Success: SIP response received with status: ${status} - ${reason}`);
            console.log('[sip-options] exiting 0 (OK)');
            finish(0);
        }
        else if (status >= 300 && status < 400) {
            console.log(`SIP OPTIONS sent to ${targetUri} - Warning: SIP response received with status: ${status} - ${reason}`);
            console.log('[sip-options] exiting 1 (warning / redirect class, not retrying)');
            finish(1);
        }
        else {
            console.log(`SIP OPTIONS sent to ${targetUri} - Failure: SIP response received with status: ${status} - ${reason}`);
            console.log('[sip-options] exiting 2 (failure class, not retrying)');
            finish(2);
        }
    });
}

sendOptions();
