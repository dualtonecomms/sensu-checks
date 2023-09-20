const sip = require('sip');
const fp = require("find-free-port")

fp(3000, 3100, (err, freePort) => {
    sip.start({
        port: freePort
    }, function (rq) {});

    function rstring() { return Math.floor(Math.random()*1e6).toString(); }
    
    const r = {
        method: 'OPTIONS',
        uri: process.argv[2],
        headers: {
            to: { uri: 'sip:ping@dualtone' },
            from: { uri: 'sip:ping@dualtone', params: {tag: rstring()} },
            'call-id': rstring(),
            'User-Agent': 'Dualtone SIP Pinger',
            cseq: { method: 'OPTIONS', seq: Math.floor(Math.random() * 1e5) },
            'content-type': 'application/sdp',
        }
    };
    
    sip.send(r, (response) => {
        if (response.status >= 200 && response.status < 300) {
            console.log(`SIP OPTIONS packed to ${process.argv[2]} - Success: SIP response received with status: ${response.status} - ${response.reason}`);
            process.exit(0);
        }
        else if (response.status >= 300 && response.status < 400) {
            console.log(`SIP OPTIONS packed to ${process.argv[2]} - Warning: SIP response received with status: ${response.status} - ${response.reason}`);
            process.exit(1);
        }
        else {
            console.log(`SIP OPTIONS packed to ${process.argv[2]} - Failure: SIP response received with status: ${response.status} - ${response.reason}`);
            process.exit(2);
        }
    });
    
})