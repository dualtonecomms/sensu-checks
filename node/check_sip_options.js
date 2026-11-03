const sip = require('sip');

const targetUri = process.argv[2];
const bindPort = parsePositiveInteger(process.argv[3], 3000);
const responseTimeoutMs = parsePositiveInteger(process.env.SIP_OPTIONS_TIMEOUT_MS || process.argv[4], 3000);
const maxAttempts = 2;

function parsePositiveInteger(value, fallback) {
    const parsed = value === undefined ? fallback : Number(value);
    return Number.isInteger(parsed) && parsed > 0 ? parsed : null;
}

function log(...args) {
    console.log(new Date().toISOString(), ...args);
}

function stopSipStack() {
    if (typeof sip.stop !== 'function') {
        return;
    }

    try {
        sip.stop();
    }
    catch (err) {
        log('[sip-options] error stopping local SIP stack:', err.message || err);
    }
}

let finished = false;
let responseTimeout;
let attempt = 0;

function finish(exitCode) {
    if (finished) {
        return;
    }

    finished = true;
    clearTimeout(responseTimeout);
    stopSipStack();
    process.exit(exitCode);
}

const parsedTarget = targetUri && sip.parseUri(targetUri);
if (!parsedTarget || parsedTarget.port === 0 || parsedTarget.port > 65535 ||
    !bindPort || bindPort > 65535 || !responseTimeoutMs || responseTimeoutMs > 2147483647) {
    log('[sip-options] invalid target URI, bind port or response timeout');
    process.exit(3);
}

process.on('uncaughtException', (err) => {
    log('[sip-options] local SIP stack error:', err.code || '', err.message || err);
    finish(2);
});

log('[sip-options] starting local SIP stack');
log('[sip-options] bind port:', bindPort);
log('[sip-options] target SIP URI:', targetUri);
log('[sip-options] response timeout:', responseTimeoutMs + 'ms');
log('[sip-options] timeout retries:', maxAttempts - 1);

sip.start({
    port: bindPort,
}, function (rq) {});

function rstring() { return Math.floor(Math.random()*1e6).toString(); }

function sendOptions() {
    attempt += 1;

    const fromTag = rstring();
    const callId = rstring();
    const cseqSeq = Math.floor(Math.random() * 1e5);

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
        log('[sip-options] timeout retry:', attempt + '/' + maxAttempts);
    }
    log('[sip-options] request method:', r.method);
    log('[sip-options] request URI:', r.uri);
    log('[sip-options] From tag:', fromTag);
    log('[sip-options] Call-ID:', callId);
    log('[sip-options] CSeq:', cseqSeq, r.headers.cseq.method);
    log('[sip-options] User-Agent:', r.headers['User-Agent']);
    log('[sip-options] sending OPTIONS and awaiting response');

    clearTimeout(responseTimeout);
    responseTimeout = setTimeout(() => {
        if (finished) {
            return;
        }

        log('[sip-options] timed out awaiting response');

        if (attempt < maxAttempts) {
            log('[sip-options] retrying OPTIONS after timeout');
            sendOptions();
            return;
        }

        log(`SIP OPTIONS sent to ${targetUri} - Failure: no SIP response received within ${responseTimeoutMs}ms after ${maxAttempts} attempts`);
        log('[sip-options] exiting 2 (timeout)');
        finish(2);
    }, responseTimeoutMs);

    sip.send(r, (response) => {
        if (finished) {
            return;
        }

        const responseCallId = response && response.headers && response.headers['call-id'];
        // A reply to the first attempt is still valid while the retry is running.
        if (responseCallId && responseCallId !== callId) {
            return;
        }

        const status = response && response.status;
        const reason = response && response.reason;
        const headerKeys = response && response.headers ? Object.keys(response.headers) : [];

        log('[sip-options] response received');
        log('[sip-options] status:', status);
        log('[sip-options] reason:', reason);
        if (headerKeys.length) {
            log('[sip-options] response header names:', headerKeys.join(', '));
        }

        if (!Number.isInteger(status) || status < 100 || status > 699) {
            log(`SIP OPTIONS sent to ${targetUri} - Failure: invalid SIP response status`);
            log('[sip-options] exiting 2 (invalid response, not retrying)');
            finish(2);
        }
        else if (status < 200) {
            log('[sip-options] provisional response; still awaiting a final response');
        }
        else if (status >= 200 && status < 300) {
            log(`SIP OPTIONS sent to ${targetUri} - Success: SIP response received with status: ${status} - ${reason}`);
            log('[sip-options] exiting 0 (OK)');
            finish(0);
        }
        else if (status >= 300 && status < 400) {
            log(`SIP OPTIONS sent to ${targetUri} - Warning: SIP response received with status: ${status} - ${reason}`);
            log('[sip-options] exiting 1 (warning / redirect class, not retrying)');
            finish(1);
        }
        else {
            log(`SIP OPTIONS sent to ${targetUri} - Failure: SIP response received with status: ${status} - ${reason}`);
            log('[sip-options] exiting 2 (failure class, not retrying)');
            finish(2);
        }
    });
}

sendOptions();
