const { NodeSDK } = require('@opentelemetry/sdk-node');
const { getNodeAutoInstrumentations } = require('@opentelemetry/auto-instrumentations-node');
const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-http');
const { OTLPMetricExporter } = require('@opentelemetry/exporter-metrics-otlp-http');
const { PeriodicExportingMetricReader } = require('@opentelemetry/sdk-metrics');
const { diag, DiagConsoleLogger, DiagLogLevel } = require('@opentelemetry/api');

if (process.env.OTEL_ENABLED === 'false') {
  module.exports = { stop: async () => {} };
  return;
}

if (process.env.OTEL_LOG_LEVEL === 'debug') {
  diag.setLogger(new DiagConsoleLogger(), DiagLogLevel.DEBUG);
}

const endpoint = process.env.OTEL_EXPORTER_OTLP_ENDPOINT || 'http://otel-collector.observability.svc.cluster.local:4318';
const traceExporter = new OTLPTraceExporter({ url: `${endpoint}/v1/traces` });
const metricExporter = new OTLPMetricExporter({ url: `${endpoint}/v1/metrics` });

const sdk = new NodeSDK({
  serviceName: process.env.OTEL_SERVICE_NAME || 'sample-node-app',
  traceExporter,
  metricReader: new PeriodicExportingMetricReader({
    exporter: metricExporter,
    exportIntervalMillis: 15000
  }),
  instrumentations: [getNodeAutoInstrumentations()]
});

try {
  const started = sdk.start();
  if (started && typeof started.then === 'function') {
    started.catch((err) => {
      // eslint-disable-next-line no-console
      console.error('OTel initialization failed:', err);
    });
  }
} catch (err) {
  // eslint-disable-next-line no-console
  console.error('OTel initialization failed:', err);
}

module.exports = {
  stop: async () => {
    await sdk.shutdown();
  }
};
