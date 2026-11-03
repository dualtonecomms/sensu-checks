'use strict';

const http = require('http');

const [,, username, password, hostname, criticalArg, warningArg, portArg] = process.argv;
const critical = Number(criticalArg);
const warning = Number(warningArg);
const port = portArg === undefined ? 15672 : Number(portArg);

function validThreshold(value) {
  return Number.isSafeInteger(value) && value >= 0;
}

if (process.argv.length < 7 || !hostname || !/^\d+$/.test(criticalArg || '') ||
    !/^\d+$/.test(warningArg || '') || !validThreshold(critical) ||
    !validThreshold(warning) || warning > critical ||
    (portArg !== undefined && !/^\d+$/.test(portArg)) ||
    !Number.isInteger(port) || port < 1 || port > 65535) {
  console.log('UNKNOWN: usage: node check_rabbit_mq.js <username> <password> <hostname> <criticalThreshold> <warningThreshold> [port]');
  process.exit(3);
}

let finished = false;
let deadline;
let request;

function finish(code, message) {
  if (finished) return;
  finished = true;
  clearTimeout(deadline);
  console.log(message);
  process.exitCode = code;
}

try {
  const auth = Buffer.from(`${username}:${password}`).toString('base64');
  request = http.request({
    hostname,
    port,
    path: '/api/queues',
    method: 'GET',
    headers: { Authorization: `Basic ${auth}` },
  }, (response) => {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      response.destroy();
      finish(3, `UNKNOWN: RabbitMQ management API returned HTTP ${response.statusCode}`);
      return;
    }

    let data = '';
    response.setEncoding('utf8');
    response.on('data', (chunk) => {
      data += chunk;
      if (data.length > 8 * 1024 * 1024) {
        response.destroy();
        finish(3, 'UNKNOWN: RabbitMQ management response was too large');
      }
    });
    response.on('aborted', () => finish(3, 'UNKNOWN: RabbitMQ management response was interrupted'));
    response.on('error', () => finish(3, 'UNKNOWN: RabbitMQ management response failed'));
    response.on('end', () => {
      let queues;
      try {
        queues = JSON.parse(data);
      } catch (_) {
        finish(3, 'UNKNOWN: RabbitMQ management API returned invalid JSON');
        return;
      }
      if (!Array.isArray(queues) || queues.some((queue) => !queue ||
          typeof queue.name !== 'string' || !validThreshold(queue.messages))) {
        finish(3, 'UNKNOWN: RabbitMQ management API returned invalid queue data');
        return;
      }

      let status = 0;
      const lines = queues.map((queue) => {
        const name = queue.name.replace(/[\r\n]/g, ' ');
        if (queue.messages > critical) {
          status = 2;
          return `CRITICAL: ${name} has ${queue.messages} messages.`;
        }
        if (queue.messages > warning) {
          if (status !== 2) status = 1;
          return `WARNING: ${name} has ${queue.messages} messages.`;
        }
        return `${name} has ${queue.messages} messages.`;
      });
      finish(status, lines.length ? lines.join('\n') : 'OK: RabbitMQ has no queues.');
    });
  });

  request.on('error', () => finish(3, 'UNKNOWN: unable to reach the RabbitMQ management API'));
  deadline = setTimeout(() => {
    request.destroy();
    finish(3, 'UNKNOWN: RabbitMQ management request timed out');
  }, 10000);
  request.end();
} catch (_) {
  finish(3, 'UNKNOWN: unable to start the RabbitMQ management request');
}
