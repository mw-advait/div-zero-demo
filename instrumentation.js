// Loaded via `node --require ./instrumentation.js` so the agent starts before app code.
//
// The Middleware agent reads these env vars:
//   MW_TARGET=https://<uid>.middleware.io:443
//   MW_API_KEY=<api-key>
//   MW_SERVICE_NAME (optional, defaults to div-zero-demo below)
//
// Local stack (https://<uid>.mw.lc) uses a cert signed by the private MwCA root.
// The gRPC exporter does not read the OS trust store, so run `npm run start:local`,
// which sets OTEL_EXPORTER_OTLP_CERTIFICATE=./mw-ca.crt (copy of /usr/local/share/ca-certificates/MwCA.crt).
const dotenv = require('dotenv');
dotenv.config();

const tracker = require('@middleware.io/node-apm');

tracker.track({
  target: process.env.MW_TARGET,
  accessToken: process.env.MW_API_KEY,
  serviceName: process.env.MW_SERVICE_NAME || 'div-zero-demo',
  projectName: 'opsai-demo',
  // Profiler auth always hits prod app.middleware.io, which rejects stage keys with 401.
  enableProfiling: false,
});

module.exports = tracker;
