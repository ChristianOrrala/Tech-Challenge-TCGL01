// CloudWatch Synthetics heartbeat. Runs on the puppeteer runtime but drives
// no browser - a REST heartbeat needs none of it. Plain `https` GETs are
// enough, and throwing on failure is all Synthetics needs to record the run
// as failed and drop SuccessPercent for this canary.

const https = require('https');

// GETs a path on the target host. Resolves with { statusCode, body };
// rejects on a transport error or timeout.
function get(host, path) {
  return new Promise((resolve, reject) => {
    // Managed WAF rule sets reject requests without a User-Agent; the canary
    // identifies itself instead of asking the firewall for an exception.
    const headers = { 'user-agent': 'tcgl01-heartbeat/1.0 (synthetics)' };
    const req = https.get({ host, path, headers, timeout: 10000 }, (res) => {
      let body = '';
      res.on('data', (chunk) => {
        body += chunk;
      });
      res.on('end', () => resolve({ statusCode: res.statusCode, body }));
    });

    req.on('error', reject);
    req.on('timeout', () => req.destroy(new Error(`request to ${path} timed out`)));
  });
}

exports.handler = async () => {
  const host = process.env.TARGET_HOST;
  if (!host) {
    throw new Error('TARGET_HOST environment variable is not set');
  }

  // Step 1: the SPA entry point must be reachable through CloudFront.
  const home = await get(host, '/');
  if (home.statusCode !== 200) {
    throw new Error(`GET / returned ${home.statusCode}, expected 200`);
  }

  // Step 2: the API must be reachable through the same distribution and
  // report a freshness timestamp for the ingested data.
  const freshness = await get(host, '/api/meta/freshness');
  if (freshness.statusCode !== 200) {
    throw new Error(`GET /api/meta/freshness returned ${freshness.statusCode}, expected 200`);
  }

  let payload;
  try {
    payload = JSON.parse(freshness.body);
  } catch (err) {
    throw new Error(`GET /api/meta/freshness returned a non-JSON body: ${err.message}`);
  }

  if (payload === null || typeof payload !== 'object' || !('age_seconds' in payload)) {
    throw new Error('GET /api/meta/freshness response is missing "age_seconds"');
  }

  return 'heartbeat ok';
};
