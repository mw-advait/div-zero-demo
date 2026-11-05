#!/usr/bin/env bash
# Runs div-zero-demo against MW_TARGET from .env (local stack advait.mw.lc, or stage)
# and emits failing ZeroDivisionError traces.
#
# Usage: ./run-local.sh [ITERATIONS]
#   ITERATIONS       number of failing traces to emit (default 1)
#   ERROR_VARIANT    optional env override for the per-run tag; set it to reuse an
#                    existing error group instead of creating a new one
#   MW_SERVICE_NAME  optional fixed service name; default is div-zero-demo-<tag>
#   VERIFY=0         skip watching quickwit-consumer for the publish (default: watch
#                    for up to VERIFY_TIMEOUT seconds, default 240)
#
# Why the service name changes per run: quickwit-consumer groups exceptions by
# embedding similarity, and its vector search is scoped to (account, service).
# Two runs of this app on the same service name differ only by the random tag, so
# the second run is ~identical in embedding space and merges into the first run's
# group. A merged span is not a new group, and the consumer only calls
# check-incident-eligibility (and publishes to v6.qtw.opsai-automation.<project>)
# for a new group. A fresh service name has no vectors to match, so every run is
# a new group, a new incident, and (if the project is eligible) a new message on
# the topic. The tag is letters only because fingerprinting normalizes away digits.
#
# The trade-off: each run adds one service to the APM services list. Set
# MW_SERVICE_NAME=div-zero-demo to keep one service (and accept merging).
#
# The local stack's TLS cert is signed by the private MwCA root. node-apm's gRPC
# exporter does not read the OS trust store, so without the CA the export fails
# and haproxy logs "SSL handshake failure". OTEL_EXPORTER_OTLP_CERTIFICATE fixes that,
# and is only set when the target is *.mw.lc.
set -euo pipefail

cd "$(dirname "$0")"

if [[ ! -f .env ]]; then
  echo ".env missing: needs MW_TARGET and MW_API_KEY" >&2
  exit 1
fi

# An exported MW_TARGET wins over .env, same as dotenv does in instrumentation.js.
MW_TARGET_RESOLVED="${MW_TARGET:-$(grep -E '^[[:space:]]*MW_TARGET=' .env | tail -n1 | cut -d= -f2- | tr -d "\"' ")}"
echo "target:          ${MW_TARGET_RESOLVED}"

# OTEL_EXPORTER_OTLP_CERTIFICATE replaces the exporter's trusted roots, so only set it for
# the local stack; with it set, the public cert on stage/prod fails verification.
if [[ "$MW_TARGET_RESOLVED" == *.mw.lc* ]]; then
  CA_CERT="${CA_CERT:-./mw-ca.crt}"
  if [[ ! -f "$CA_CERT" ]]; then
    if [[ -f /usr/local/share/ca-certificates/MwCA.crt ]]; then
      cp /usr/local/share/ca-certificates/MwCA.crt "$CA_CERT"
    else
      echo "CA cert not found at $CA_CERT (and no /usr/local/share/ca-certificates/MwCA.crt to copy)" >&2
      exit 1
    fi
  fi
  export OTEL_EXPORTER_OTLP_CERTIFICATE="$CA_CERT"
else
  unset OTEL_EXPORTER_OTLP_CERTIFICATE
fi
export ITERATIONS="${1:-${ITERATIONS:-1}}"
# Random 10-letter tag. tr gets SIGPIPE when dd stops reading; export masks that exit code.
export ERROR_VARIANT="${ERROR_VARIANT:-$(LC_ALL=C tr -dc 'a-z' < /dev/urandom 2>/dev/null | dd bs=10 count=1 status=none)}"

export MW_SERVICE_NAME="${MW_SERVICE_NAME:-div-zero-demo-${ERROR_VARIANT}}"

echo "service:         ${MW_SERVICE_NAME}"
echo "error group tag: ZeroDivisionError_${ERROR_VARIANT}"

START_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# The app exits 1 on purpose when a ZeroDivisionError is thrown; don't treat that as a failure here.
node --require ./instrumentation.js index.js || true

# Optional: follow the span through quickwit-consumer. Needs docker access to the local stack.
if [[ "${VERIFY:-1}" == "1" ]] && command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx quickwit-consumer; then
  timeout_s="${VERIFY_TIMEOUT:-240}"
  echo "waiting up to ${timeout_s}s for quickwit-consumer to group + check eligibility ..."
  deadline=$((SECONDS + timeout_s))
  while (( SECONDS < deadline )); do
    # Lines for this run: the grouping line carries no service, so take everything since START_TS
    # and keep the grouping/eligibility/publish lines; our span is the only new group in the window
    # unless something else is also emitting.
    out="$(docker logs quickwit-consumer --since "$START_TS" 2>&1 \
      | grep -E 'merge grouping|published eligible|not eligible|Error publishing|checkTraceEligibility.*done' || true)"
    if grep -qE 'done for fingerprint|Error publishing' <<<"$out"; then
      echo "$out"
      if grep -q 'Successfully published' <<<"$out"; then
        echo "RESULT: published to v6.qtw.opsai-automation topic"
      elif grep -q 'not eligible' <<<"$out"; then
        echo "RESULT: new group created but NOT eligible (see reason above: limit reached / schedule mode / auto-investigation off)"
      else
        echo "RESULT: eligibility call failed (see error above); the incident will not be retried"
      fi
      exit 0
    fi
    sleep 3
  done
  echo "RESULT: no grouping/eligibility line within ${timeout_s}s. Check: docker logs quickwit-consumer --since $START_TS"
fi
