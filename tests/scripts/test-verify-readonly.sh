#!/usr/bin/env bash
# Enforces that scripts/verify is read-only.
#
# "It's read-only" is a claim people act on: they run it against
# production, during an incident, with elevated credentials. So it is
# tested rather than asserted.
#
# Three independent checks, because each catches what the others miss:
#
#   1. STATIC: no AWS write verb appears anywhere in the source.
#   2. GATE: the aws_read() allowlist rejects non-read operations.
#   3. BEHAVIOURAL: run the real script against a fake `aws` on PATH
#      that records every invocation, then assert every recorded call
#      was a read. This is the one that catches a write hidden behind a
#      variable or an eval.
#
# Needs no AWS credentials and makes no network calls.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERIFY="${REPO_ROOT}/scripts/verify"

FAILURES=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() {
  printf '  FAIL  %s\n' "$1"
  FAILURES=$((FAILURES + 1))
}

printf 'test-verify-readonly: proving scripts/verify makes no AWS write calls\n\n'

[ -f "${VERIFY}" ] || {
  printf 'scripts/verify not found at %s\n' "${VERIFY}" >&2
  exit 1
}

# ---------------------------------------------------------------------
# 1. Static analysis
# ---------------------------------------------------------------------
printf '1. static: no write verbs in the source\n'

# Verbs that mutate. Deliberately broad: a false positive here is a
# comment to reword, a false negative is a script that changes
# production.
WRITE_VERBS=(
  create delete put update modify set attach detach
  terminate stop start reboot run authorize revoke
  associate disassociate register deregister
  enable disable tag untag remove add replace
  import export copy restore cancel send invoke
  reset apply upload
)

for verb in "${WRITE_VERBS[@]}"; do
  # Match an aws_read/aws invocation whose operation begins with the
  # verb, e.g. `aws ec2 create-tags` or `aws_read ec2 delete-volume`.
  if grep -nE "aws(_read)?[[:space:]]+[a-z0-9-]+[[:space:]]+${verb}(-|[[:space:]]|$)" "${VERIFY}" |
    grep -v '^\s*#' | grep -q .; then
    fail "found a possible '${verb}' operation:"
    grep -nE "aws(_read)?[[:space:]]+[a-z0-9-]+[[:space:]]+${verb}(-|[[:space:]]|$)" "${VERIFY}" >&2
  fi
done

if ! grep -qE '^\s*aws_read\(\)' "${VERIFY}"; then
  fail "aws_read() gate function is missing -- the read-only contract depends on it"
else
  pass "aws_read() gate function present"
fi

# Every AWS call must go through the gate. A bare `aws ` call bypasses
# it, so the only permitted bare uses are the prerequisite check and
# inside aws_read itself.
bare_calls="$(grep -nE '(^|[^_[:alnum:]])aws[[:space:]]+(ec2|ssm|logs|s3api|s3|iam|kms|autoscaling|sts)[[:space:]]' "${VERIFY}" |
  grep -vE 'aws_read' || true)"

if [ -n "${bare_calls}" ]; then
  # Permitted: the `args+=(aws ...)` construction inside aws_read.
  unexpected="$(printf '%s' "${bare_calls}" | grep -vE 'args=\(aws' || true)"
  if [ -n "${unexpected}" ]; then
    fail "AWS calls that bypass the aws_read() gate:"
    printf '%s\n' "${unexpected}" >&2
  else
    pass "all AWS calls go through aws_read()"
  fi
else
  pass "all AWS calls go through aws_read()"
fi

if [ "${FAILURES}" -eq 0 ]; then
  pass "no write verbs found in source"
fi

# ---------------------------------------------------------------------
# 2. The gate rejects writes
# ---------------------------------------------------------------------
printf '\n2. gate: aws_read() rejects non-read operations\n'

# Source only the gate, with the surrounding script's side effects
# stubbed, and call it with write operations.
GATE_TEST="$(mktemp)"
trap 'rm -f "${GATE_TEST}"' EXIT

{
  # Extract the aws_read function and the die() it depends on.
  printf 'set -euo pipefail\n'
  printf 'REGION=""\nPROFILE=""\n'
  printf 'die() { printf "error: %%s\\n" "$*" >&2; exit 2; }\n'
  sed -n '/^aws_read() {/,/^}/p' "${VERIFY}"
} >"${GATE_TEST}"

for op in create-tags delete-volume put-parameter terminate-instances modify-instance-attribute; do
  if bash -c "source '${GATE_TEST}'; aws_read ec2 ${op} >/dev/null 2>&1"; then
    fail "aws_read() accepted write operation '${op}'"
  else
    pass "aws_read() rejected '${op}'"
  fi
done

# And still permits reads. The command will fail (no credentials, and
# `aws` may not exist), but it must get PAST the gate -- exit code 2 is
# the gate's own refusal, so anything else means it was allowed through.
for op in describe-instances list-buckets get-bucket-versioning; do
  set +e
  bash -c "source '${GATE_TEST}'; aws_read ec2 ${op} >/dev/null 2>&1"
  rc=$?
  set -e
  if [ "${rc}" -eq 2 ]; then
    fail "aws_read() rejected read operation '${op}'"
  else
    pass "aws_read() permitted '${op}'"
  fi
done

# ---------------------------------------------------------------------
# 3. Behavioural: run it for real against a recording fake
# ---------------------------------------------------------------------
printf '\n3. behavioural: every call the script actually makes is a read\n'

FAKE_BIN="$(mktemp -d)"
CALL_LOG="${FAKE_BIN}/calls.log"
trap 'rm -f "${GATE_TEST}"; rm -rf "${FAKE_BIN}"' EXIT

# A fake `aws` that records its arguments and returns plausible empty
# JSON, so the script runs to completion and exercises every check.
cat >"${FAKE_BIN}/aws" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CALL_LOG}"

# Strip global options to find the service and operation.
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --region|--profile) shift 2 ;;
    --output) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done

service="${args[0]:-}"
operation="${args[1]:-}"

case "${service} ${operation}" in
  "sts get-caller-identity") echo '{"Account":"111122223333","Arn":"arn:aws:iam::111122223333:user/test"}' ;;
  "ec2 describe-instances") echo '{"Reservations":[]}' ;;
  "ec2 describe-security-groups") echo '{"SecurityGroups":[]}' ;;
  "ec2 describe-volumes") echo '{"Volumes":[]}' ;;
  "ssm describe-instance-information") echo '{"InstanceInformationList":[]}' ;;
  "logs describe-log-groups") echo '{"logGroups":[]}' ;;
  "s3api get-public-access-block") echo '{"PublicAccessBlockConfiguration":{}}' ;;
  "s3api get-bucket-encryption") echo '{"ServerSideEncryptionConfiguration":{"Rules":[]}}' ;;
  "s3api get-bucket-versioning") echo '{}' ;;
  *) echo '{}' ;;
esac
FAKE
chmod +x "${FAKE_BIN}/aws"

export CALL_LOG
: >"${CALL_LOG}"

# Run the real script with the fake first on PATH, exercising every
# check including the optional logging and S3 ones.
set +e
PATH="${FAKE_BIN}:${PATH}" "${VERIFY}" \
  --tag "BastionFreeAccess=test" \
  --log-group "/aws/ssm/test/sessions" \
  --s3-bucket "test-bucket" \
  --region "us-east-1" \
  --json >/dev/null 2>&1
verify_rc=$?
set -e

printf '     (verify exited %d; exit code is not what this test asserts)\n' "${verify_rc}"

if [ ! -s "${CALL_LOG}" ]; then
  fail "the script made no AWS calls at all -- the fake was not used, so this test proved nothing"
else
  call_count="$(wc -l <"${CALL_LOG}" | tr -d ' ')"
  pass "recorded ${call_count} AWS call(s) through the fake"

  # Every recorded call's operation must be a read.
  bad=0
  while IFS= read -r line; do
    # Drop global options, then take the second remaining token.
    op="$(printf '%s\n' "${line}" |
      sed -E 's/--(region|profile|output)[[:space:]]+[^[:space:]]+//g' |
      awk '{print $2}')"

    case "${op}" in
      describe-* | list-* | get-*) ;;
      "") ;; # e.g. `aws --version`
      *)
        fail "non-read operation actually invoked: '${op}' (full call: ${line})"
        bad=1
        ;;
    esac
  done <"${CALL_LOG}"

  [ "${bad}" -eq 0 ] && pass "every recorded call was describe-*, list-*, or get-*"
fi

# ---------------------------------------------------------------------
printf '\n'
if [ "${FAILURES}" -gt 0 ]; then
  printf 'FAILED: %d check(s) failed. scripts/verify cannot be described as read-only.\n' "${FAILURES}"
  exit 1
fi
printf 'PASSED: scripts/verify is read-only (static, gate, and behavioural checks).\n'
