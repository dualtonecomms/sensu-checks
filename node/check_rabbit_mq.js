const http = require('http');

const checkMessages = async (username, password, hostname, criticalThreshold, warningThreshold, port = 15672) => {
  try {
    const auth = Buffer.from(`${username}:${password}`).toString('base64');

    const options = {
      hostname: hostname,
      port: port,
      path: '/api/queues',
      method: 'GET',
      headers: {
        'Authorization': `Basic ${auth}`,
      },
    };

    const request = http.request(options, (res) => {
      let data = '';

      res.on('data', (chunk) => {
        data += chunk;
      });

      res.on('end', () => {
        const items = JSON.parse(data);
        let exitCode = 0;

        items.forEach(item => {
          const messageCount = item.messages;
          const name = item.name;
          if (messageCount > criticalThreshold) {
            console.log(`CRITICAL: ${name} has ${messageCount} messages.`);
            exitCode = 2;
          } else if (messageCount > warningThreshold) {
            console.log(`WARNING: ${name} has ${messageCount} messages.`);
            exitCode = exitCode === 2 ? exitCode : 1;
          } else {
            console.log(`${name} has ${messageCount} messages.`);
          }
        });

        process.exit(exitCode);
      });
    });

    request.on('error', (error) => {
      console.error('Error fetching data:', error);
    });

    request.end();
  } catch (error) {
    console.error('Error:', error);
  }
};

if (process.argv.length < 7) {
  console.log('Usage: node check_rabbit_mq.js <username> <password> <hostname> <criticalThreshold> <warningThreshold> [port]');
  process.exit(1);
}

const [,, username, password, hostname, criticalThreshold, warningThreshold, port] = process.argv;

const criticalThresholdNum = parseInt(criticalThreshold, 10);
const warningThresholdNum = parseInt(warningThreshold, 10);

checkMessages(username, password, hostname, criticalThresholdNum, warningThresholdNum, port);