const { context, trace } = require('@opentelemetry/api');

function activeTraceId() {
  const span = trace.getSpan(context.active());
  const traceId = span && span.spanContext ? span.spanContext().traceId : '';
  return traceId || undefined;
}

function writeLog(level, message, fields = {}) {
  const record = {
    timestamp: new Date().toISOString(),
    level,
    message,
    trace_id: activeTraceId(),
    ...fields
  };

  process.stdout.write(`${JSON.stringify(record)}\n`);
}

function requestLogger(serviceName) {
  return function onRequest(req, res, next) {
    const startedAt = Date.now();

    res.on('finish', () => {
      writeLog('info', 'http_request', {
        service: serviceName,
        method: req.method,
        path: req.originalUrl || req.url,
        status_code: res.statusCode,
        duration_ms: Date.now() - startedAt,
        user_agent: req.headers['user-agent'] || '',
        client_ip: req.ip || ''
      });
    });

    next();
  };
}

function info(message, fields) {
  writeLog('info', message, fields);
}

function error(message, fields) {
  writeLog('error', message, fields);
}

module.exports = {
  info,
  error,
  requestLogger
};
