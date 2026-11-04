#!/usr/bin/env bash
# Run the Goss suites against the build instance.
#
# Blocking suites: any failure exits non-zero, which aborts the Packer
# build before the AMI is created. An image whose sshd could start, or
# whose ssm-user still has sudo, must never reach a published AMI.
#
# The advisory suite is informational and never fails the build.
set -euo pipefail

GOSS_BIN="/usr/local/bin/goss"
GOSS_DIR="/tmp/goss"
RESULTS="/tmp/goss-results.json"
ADVISORY_RESULTS="/tmp/goss-advisory-results.json"

BLOCKING_SUITES=(
  "goss.yaml"
  "goss_no_ssh.yaml"
  "goss_access_node.yaml"
)

export GOSS_FILES_PATH="${GOSS_DIR}"

# Human-readable output first: when CI fails, the log should say which
# control failed without anyone having to parse JSON.
echo "=============================================================="
echo " Blocking Goss suites"
echo "=============================================================="
failed=0
for suite in "${BLOCKING_SUITES[@]}"; do
  echo "--- ${suite}"
  if ! "${GOSS_BIN}" -g "${GOSS_DIR}/${suite}" validate --format documentation; then
    echo "FAILED: ${suite}"
    failed=1
  fi
done

# Machine-readable results for the CI test job, concatenated as a JSON
# array so one file covers every blocking suite.
{
  echo "["
  first=1
  for suite in "${BLOCKING_SUITES[@]}"; do
    [ "${first}" -eq 1 ] || echo ","
    first=0
    "${GOSS_BIN}" -g "${GOSS_DIR}/${suite}" validate --format json || true
  done
  echo "]"
} >"${RESULTS}"

echo "=============================================================="
echo " Advisory Goss suite (informational, never blocking)"
echo "=============================================================="
"${GOSS_BIN}" -g "${GOSS_DIR}/goss_advisory.yaml" validate --format documentation || true
"${GOSS_BIN}" -g "${GOSS_DIR}/goss_advisory.yaml" validate --format json >"${ADVISORY_RESULTS}" 2>/dev/null || true

chmod 0644 "${RESULTS}" "${ADVISORY_RESULTS}"

if [ "${failed}" -ne 0 ]; then
  echo
  echo "One or more blocking Goss suites failed. Aborting the build so"
  echo "this image cannot be published."
  exit 1
fi

echo "All blocking Goss suites passed."
