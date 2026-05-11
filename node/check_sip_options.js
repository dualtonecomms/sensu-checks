const sip = require('sip');

const targetUri = process.argv[2];
const bindPort = Number(process.argv[3]) || 3000;

console.log('[sip-options] starting local SIP stack');
console.log('[sip-options] bind port:', bindPort);
console.log('[sip-options] target SIP URI:', targetUri || '(missing — pass as first argument)');

sip.start({
    port: bindPort,
}, function (rq) {});

function rstring() { return Math.floor(Math.random()*1e6).toString(); }

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

console.log('[sip-options] request method:', r.method);
console.log('[sip-options] request URI:', r.uri);
console.log('[sip-options] From tag:', fromTag);
console.log('[sip-options] Call-ID:', callId);
console.log('[sip-options] CSeq:', cseqSeq, r.headers.cseq.method);
console.log('[sip-options] User-Agent:', r.headers['User-Agent']);
console.log('[sip-options] sending OPTIONS and awaiting response');

sip.send(r, (response) => {
    const status = response && response.status;
    const reason = response && response.reason;
    const headerKeys = response && response.headers ? Object.keys(response.headers) : [];

    console.log('[sip-options] response received');
    console.log('[sip-options] status:', status);
    console.log('[sip-options] reason:', reason);
    if (headerKeys.length) {
        console.log('[sip-options] response header names:', headerKeys.join(', '));
    }

    if (response.status >= 200 && response.status < 300) {
        console.log(`SIP OPTIONS sent to ${targetUri} - Success: SIP response received with status: ${response.status} - ${response.reason}`);
        console.log('[sip-options] exiting 0 (OK)');
        process.exit(0);
    }
    else if (response.status >= 300 && response.status < 400) {
        console.log(`SIP OPTIONS sent to ${targetUri} - Warning: SIP response received with status: ${response.status} - ${response.reason}`);
        console.log('[sip-options] exiting 1 (warning / redirect class)');
        process.exit(1);
    }
    else {
        console.log(`SIP OPTIONS sent to ${targetUri} - Failure: SIP response received with status: ${response.status} - ${response.reason}`);
        console.log('[sip-options] exiting 2 (failure class)');
        process.exit(2);
    }
});
