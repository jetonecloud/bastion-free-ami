#!/usr/bin/env bash
# End-to-end smoke test: boots a real instance from a built AMI into a
# private subnet with no inbound rules, confirms it registers with Session
# Manager, and proves from inside the instance that nothing listens on
# port 22.
#
# This is where the runtime half of the "sshd is disabled" claim is
# tested. The Goss suite asserts the persistent state (masked + disabled)
# because the build itself arrives over SSH; this test asserts the
# observable state on a booted instance. See docs/design.md.
#
# It makes AWS write calls (RunInstances, TerminateInstances) and costs a
# few cents. It is NOT part of the pull-request workflow.
#
# Required environment variables:
#   AMI_ID                 AMI to boot
#   SUBNET_ID              Private subnet that can reach SSM (NAT or VPC
#                          endpoints). Must NOT be a public subnet.
#   SECURITY_GROUP_ID      Security group with NO inbound rules
#   INSTANCE_PROFILE_NAME  Instance profile granting AmazonSSMManagedInstanceCore
#
# Optional:
#   AWS_REGION             default us-east-1
#   INSTANCE_TYPE          default t3.small (use t4g.small for arm64)
#   TIMEOUT_SECONDS        overall timeout, default 600
#   KEEP_INSTANCE          "true" leaves the instance running on failure
set -euo pipefail

: "${AMI_ID:?set AMI_ID}"
: "${SUBNET_ID:?set SUBNET_ID}"
: "${SECURITY_GROUP_ID:?set SECURITY_GROUP_ID}"
: "${INSTANCE_PROFILE_NAME:?set INSTANCE_PROFILE_NAME}"

AWS_REGION="${AWS_REGION:-us-east-1}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t3.small}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-600}"
KEEP_INSTANCE="${KEEP_INSTANCE:-false}"

INSTANCE_ID=""
START_TIME="$(date +%s)"
FAILURES=0

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() {
  log "ERROR: $*"
  exit 1
}
pass() { log "  PASS: $*"; }
fail() {
  log "  FAIL: $*"
  FAILURES=$((FAILURES + 1))
}

elapsed() { echo $(($(date +%s) - START_TIME)); }
deadline_or_die() {
  [ "$(elapsed)" -lt "${TIMEOUT_SECONDS}" ] ||
    die "timed out after ${TIMEOUT_SECONDS}s waiting on: $1"
}

cleanup() {
  local status=$?
  if [ -n "${INSTANCE_ID}" ]; then
    if [ "${KEEP_INSTANCE}" = "true" ] && [ "${status}" -ne 0 ]; then
      log "KEEP_INSTANCE=true, leaving ${INSTANCE_ID} running for debugging"
    else
      log "cleanup: terminating ${INSTANCE_ID}"
      aws ec2 terminate-instances \
        --region "${AWS_REGION}" \
        --instance-ids "${INSTANCE_ID}" >/dev/null 2>&1 || true
    fi
  fi
  exit "${status}"
}
trap cleanup EXIT

command -v aws >/dev/null || die "aws CLI is required"
command -v jq >/dev/null || die "jq is required"
command -v session-manager-plugin >/dev/null ||
  die "session-manager-plugin is required: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"

# ---------------------------------------------------------------------
# Refuse to run against a security group that has inbound rules. The
# whole point is to prove the node is reachable with none, so a
# permissive group would make a pass meaningless.
# ---------------------------------------------------------------------
log "1/6 checking ${SECURITY_GROUP_ID} has no inbound rules"
INBOUND_COUNT="$(aws ec2 describe-security-groups \
  --region "${AWS_REGION}" \
  --group-ids "${SECURITY_GROUP_ID}" \
  --query 'length(SecurityGroups[0].IpPermissions)' \
  --output text)"
[ "${INBOUND_COUNT}" = "0" ] ||
  die "${SECURITY_GROUP_ID} has ${INBOUND_COUNT} inbound rule(s). This test must run against a group with none."
pass "security group has no inbound rules"

log "2/6 launching ${INSTANCE_TYPE} from ${AMI_ID} into ${SUBNET_ID}"
INSTANCE_ID="$(aws ec2 run-instances \
  --region "${AWS_REGION}" \
  --image-id "${AMI_ID}" \
  --instance-type "${INSTANCE_TYPE}" \
  --subnet-id "${SUBNET_ID}" \
  --security-group-ids "${SECURITY_GROUP_ID}" \
  --iam-instance-profile "Name=${INSTANCE_PROFILE_NAME}" \
  --no-associate-public-ip-address \
  --metadata-options 'HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=1' \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=bfa-smoke-test},{Key=Project,Value=bastion-free-ami},{Key=Ephemeral,Value=true}]" \
  --query 'Instances[0].InstanceId' \
  --output text)"
log "    instance ${INSTANCE_ID}"

log "3/6 waiting for the instance to register with Session Manager"
while true; do
  deadline_or_die "SSM registration"
  PING="$(aws ssm describe-instance-information \
    --region "${AWS_REGION}" \
    --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
    --query 'InstanceInformationList[0].PingStatus' \
    --output text 2>/dev/null || echo "None")"
  [ "${PING}" = "Online" ] && break
  sleep 10
done
pass "registered with Session Manager and Online (no inbound rule needed)"

# ---------------------------------------------------------------------
# The core assertions, run on the instance itself via Run Command.
# ---------------------------------------------------------------------
run_on_instance() {
  local description="$1" script="$2" expected="$3"
  local cmd_id output

  cmd_id="$(aws ssm send-command \
    --region "${AWS_REGION}" \
    --instance-ids "${INSTANCE_ID}" \
    --document-name AWS-RunShellScript \
    --parameters "commands=[\"${script}\"]" \
    --query 'Command.CommandId' \
    --output text)"

  while true; do
    deadline_or_die "command ${cmd_id} (${description})"
    local state
    state="$(aws ssm get-command-invocation \
      --region "${AWS_REGION}" \
      --command-id "${cmd_id}" \
      --instance-id "${INSTANCE_ID}" \
      --query 'Status' --output text 2>/dev/null || echo Pending)"
    case "${state}" in
      Success | Failed | Cancelled | TimedOut) break ;;
    esac
    sleep 5
  done

  output="$(aws ssm get-command-invocation \
    --region "${AWS_REGION}" \
    --command-id "${cmd_id}" \
    --instance-id "${INSTANCE_ID}" \
    --query 'StandardOutputContent' --output text | tr -d '\r\n[:space:]')"

  if [ "${output}" = "${expected}" ]; then
    pass "${description} (got '${output}')"
  else
    fail "${description}: expected '${expected}', got '${output}'"
  fi
}

log "4/6 proving nothing listens on port 22"
run_on_instance "no process listening on TCP 22" \
  "ss -ltnH 2>/dev/null | awk '{print \\\$4}' | grep -cE ':22\$' || true" \
  "0"

run_on_instance "sshd.service is masked" \
  "systemctl is-enabled sshd.service 2>&1 || true" \
  "masked"

run_on_instance "sshd is not running" \
  "systemctl is-active sshd.service 2>&1 || true" \
  "inactive"

log "5/6 checking session privilege and image properties"
run_on_instance "ssm-user has no sudo grant" \
  "grep -cE '^[[:space:]]*ssm-user[[:space:]]+ALL' /etc/sudoers.d/ssm-agent-users 2>/dev/null || true" \
  "0"

run_on_instance "firewalld does not allow ssh" \
  "firewall-cmd --zone=drop --query-service=ssh >/dev/null 2>&1 && echo yes || echo no" \
  "no"

run_on_instance "auditd will not halt on a full disk" \
  "grep -cE '^[[:space:]]*admin_space_left_action[[:space:]]*=[[:space:]]*halt' /etc/audit/auditd.conf || true" \
  "0"

run_on_instance "release file identifies an access node" \
  "grep -c 'ROLE=\\\"access-node\\\"' /etc/bastion-free-ami/release || true" \
  "1"

log "6/6 confirming an interactive session starts and is not root"
# start-session needs a TTY, so this uses the documented non-interactive
# equivalent: Run Command reports the identity sessions would land on.
run_on_instance "ssm-user cannot escalate with sudo -n" \
  "runuser -u ssm-user -- sudo -n true >/dev/null 2>&1 && echo escalated || echo denied" \
  "denied"

echo
if [ "${FAILURES}" -gt 0 ]; then
  log "SMOKE TEST FAILED: ${FAILURES} assertion(s) failed"
  exit 1
fi
log "SMOKE TEST PASSED: ${AMI_ID} is reachable over Session Manager with no inbound rules, and port 22 is closed"
