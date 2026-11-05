const tracker = require('./instrumentation');

const tracer = tracker.getTracer('div-zero-demo');

// ERROR_VARIANT (letters only) makes the error type, message and span names unique per run.
// On its own that is NOT enough for a new error group: the backend groups by embedding
// similarity within one service, and two runs differ only by the tag. run-local.sh therefore
// also sets MW_SERVICE_NAME=div-zero-demo-<tag> (read in instrumentation.js), which is what
// actually guarantees a new group, a new incident and a new message on the automation topic.
const variant = process.env.ERROR_VARIANT || '';
const suffix = variant ? `_${variant}` : '';

class ZeroDivisionError extends Error {
  constructor(dividend) {
    super(`Division by zero in ${variant || 'default'} job: attempted ${dividend} / 0`);
    this.name = `ZeroDivisionError${suffix}`;
  }
}

// JS returns Infinity for x / 0, so throw explicitly to simulate a real error.
function divide(a, b) {
  return tracer.startActiveSpan(`divide${suffix}`, (span) => {
    span.setAttributes({ 'calc.dividend': a, 'calc.divisor': b });
    try {
      if (b === 0) throw new ZeroDivisionError(a);
      const result = a / b;
      span.setAttribute('calc.result', result);
      return result;
    } catch (err) {
      // Records the exception on the active span and marks it as an error.
      tracker.errorRecord(err);
      throw err;
    } finally {
      span.end();
    }
  });
}

// Average order value per customer; the last batch has zero customers.
function computeAverages(batches) {
  return tracer.startActiveSpan(`computeAverages${suffix}`, (span) => {
    span.setAttribute('batch.count', batches.length);
    try {
      return batches.map(({ name, revenue, customers }) => {
        if (customers === 0) {
          tracker.warn?.(`${name}: skipping average, zero customers`, { batch: name });
          return null;
        }
        const avg = divide(revenue, customers);
        tracker.info(`${name}: average revenue per customer = ${avg.toFixed(2)}`, { batch: name });
        return avg;
      });
    } catch (err) {
      tracker.errorRecord(err);
      tracker.error(`computeAverages failed: ${err.message}`, {
        'exception.type': err.name,
        'exception.stacktrace': err.stack,
      });
      throw err;
    } finally {
      span.end();
    }
  });
}

async function main() {
  const batches = [
    { name: 'batch-a', revenue: 1200, customers: 4 },
    { name: 'batch-b', revenue: 900, customers: 3 },
    { name: 'batch-c', revenue: 500, customers: 0 },
  ];

  // ITERATIONS controls how many failing traces to emit (each run is its own trace).
  const iterations = Number(process.env.ITERATIONS) || 1;
  let failures = 0;
  for (let i = 0; i < iterations; i++) {
    try {
      computeAverages(batches);
    } catch (err) {
      failures++;
      if (iterations === 1) console.error(`Job failed: ${err.stack}`);
    }
    await new Promise((r) => setTimeout(r, 50));
  }
  console.log(`Emitted ${iterations} traces, ${failures} failed with ZeroDivisionError${suffix}`);
  await tracker.sdkShutdown();
  process.exit(failures > 0 ? 1 : 0);
}

main();
