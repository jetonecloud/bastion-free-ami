#!/usr/bin/env bash
# Fetch the hardened-al2023 Ansible roles at a pinned tag.
#
# Only needed for al2023-base build mode (apply_upstream_hardening=true).
# In the default mode the source AMI already has these roles applied and
# this script should not run at all.
#
# The roles are cloned, never vendored into this repository: vendoring two
# copies of a CIS baseline guarantees they drift. See docs/design.md,
# "Decision: how this builds on hardened-al2023".
set -euo pipefail

# Pinned deliberately. Bump this, re-run a build, and check the Goss
# results before committing the bump.
UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/jetonecloud/hardened-al2023.git}"
UPSTREAM_REF="${UPSTREAM_REF:-v0.1.0}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${REPO_ROOT}/ansible/.upstream/hardened-al2023"

if [ -d "${DEST}/.git" ]; then
  echo "Updating ${DEST} to ${UPSTREAM_REF}"
  git -C "${DEST}" fetch --tags --depth 1 origin "${UPSTREAM_REF}"
  git -C "${DEST}" checkout --quiet FETCH_HEAD
else
  echo "Cloning ${UPSTREAM_REPO} at ${UPSTREAM_REF} into ${DEST}"
  mkdir -p "$(dirname "${DEST}")"
  git clone --quiet --depth 1 --branch "${UPSTREAM_REF}" "${UPSTREAM_REPO}" "${DEST}"
fi

RESOLVED="$(git -C "${DEST}" rev-parse HEAD)"
echo "hardened-al2023 at ${UPSTREAM_REF} (${RESOLVED})"

ROLES_DIR="${DEST}/ansible/roles"
if [ ! -d "${ROLES_DIR}" ]; then
  echo "ERROR: expected roles at ${ROLES_DIR} -- upstream layout changed?" >&2
  exit 1
fi

# Fail loudly if an expected role disappeared upstream, rather than
# silently building an image with less hardening than the docs claim.
for role in common ssh kernel network auditd logging; do
  if [ ! -d "${ROLES_DIR}/${role}" ]; then
    echo "ERROR: upstream role '${role}' not found at ${UPSTREAM_REF}" >&2
    exit 1
  fi
done

echo "Roles available: $(ls "${ROLES_DIR}" | tr '\n' ' ')"
echo
echo "Add to ANSIBLE_ROLES_PATH:"
echo "  ${ROLES_DIR}"
