#!/usr/bin/env bash
# Trivy filesystem scan of the build instance: OS package vulnerabilities,
# baked-in secrets, and config misconfigurations.
#
# Runs before cleanup so the scan sees everything that will ship in the
# AMI. By default this does not fail the Packer build -- OS package CVEs
# can appear upstream faster than anyone can fix them here -- but the CI
# pipeline parses the report and blocks publishing on any CRITICAL finding
# or exposed secret. Set TRIVY_FAIL_ON_CRITICAL=true to fail locally too.
set -euo pipefail

TRIVY_BIN="/usr/local/bin/trivy"
REPORT="/tmp/trivy-report.json"
SEVERITY="${TRIVY_SEVERITY:-HIGH,CRITICAL}"
FAIL_ON_CRITICAL="${TRIVY_FAIL_ON_CRITICAL:-false}"

export TRIVY_NO_PROGRESS=true
export TRIVY_CACHE_DIR=/tmp/trivy-cache

echo "Running Trivy filesystem scan (severity: ${SEVERITY})"
"${TRIVY_BIN}" filesystem / \
  --scanners vuln,secret,misconfig \
  --severity "${SEVERITY}" \
  --format json \
  --output "${REPORT}" \
  --skip-dirs /proc \
  --skip-dirs /sys \
  --skip-dirs /dev \
  --skip-dirs /tmp/trivy-cache \
  --skip-dirs /var/lib/amazon

chmod 0644 "${REPORT}"

CRITICAL=$(python3 -c "
import json
with open('${REPORT}') as f:
    data = json.load(f)
n = 0
for r in data.get('Results') or []:
    for v in r.get('Vulnerabilities') or []:
        if v.get('Severity') == 'CRITICAL':
            n += 1
print(n)
")
SECRETS=$(python3 -c "
import json
with open('${REPORT}') as f:
    data = json.load(f)
print(sum(len(r.get('Secrets') or []) for r in (data.get('Results') or [])))
")

echo "Trivy: ${CRITICAL} CRITICAL vulnerabilities, ${SECRETS} secrets"

# A baked secret always fails the build, regardless of the flag. "No
# secrets in the image" is a hard requirement of this project, not a
# severity threshold to be tuned.
if [ "${SECRETS}" -gt 0 ]; then
  echo "ERROR: Trivy found secrets baked into the image. Aborting."
  python3 -c "
import json
with open('${REPORT}') as f:
    data = json.load(f)
for r in data.get('Results') or []:
    for s in r.get('Secrets') or []:
        print('  {}: {} ({})'.format(r.get('Target'), s.get('RuleID'), s.get('Title')))
"
  exit 1
fi

if [ "${FAIL_ON_CRITICAL}" = "true" ] && [ "${CRITICAL}" -gt 0 ]; then
  echo "ERROR: ${CRITICAL} CRITICAL vulnerabilities and TRIVY_FAIL_ON_CRITICAL=true. Aborting."
  exit 1
fi

echo "Trivy scan complete; report at ${REPORT}"
