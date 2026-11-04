#!/usr/bin/env bash
# Final provisioner. Removes everything the build itself introduced, then
# stops sshd.
#
# This MUST be the last provisioner in build.pkr.hcl. Stopping sshd closes
# the listener; the already-established connection running this script
# survives because sshd forks a child per connection, but nothing can
# connect afterwards. Any provisioner added after this one will fail to
# reconnect.
#
# `|| true` appears on the systemctl calls deliberately: the unit is
# already masked by the access_node role, so systemd may report an error
# for an operation that is already a no-op. The role is what guarantees
# the persistent state; this script is best-effort tidying of the running
# instance.
set -euo pipefail

echo "--- Removing build-time SSH material"
# Packer's ephemeral public key lands in the build user's authorized_keys.
# The key pair is discarded by Packer when the build ends, but the
# authorized_keys entry would otherwise be baked into the AMI.
for home in /root /home/*; do
  if [ -d "${home}/.ssh" ]; then
    rm -f "${home}/.ssh/authorized_keys" \
      "${home}/.ssh/authorized_keys2" \
      "${home}/.ssh/id_"* \
      "${home}/.ssh/known_hosts"
  fi
done

# Regenerated on first boot by cloud-init if sshd were ever unmasked.
# Leaving them baked in would mean every instance from this AMI shares a
# host identity.
echo "--- Removing baked SSH host keys"
rm -f /etc/ssh/ssh_host_*

echo "--- Clearing machine identity so each instance gets its own"
: >/etc/machine-id
rm -f /var/lib/systemd/random-seed

echo "--- Clearing cloud-init state"
cloud-init clean --logs --seed 2>/dev/null || rm -rf /var/lib/cloud/*

echo "--- Clearing package manager caches"
dnf clean all
rm -rf /var/cache/dnf/* /var/cache/yum/*

echo "--- Clearing build artefacts and tooling"
rm -rf /tmp/goss /tmp/trivy-cache /usr/local/bin/goss /usr/local/bin/trivy
# Reports were already downloaded by Packer.
rm -f /tmp/goss-results.json /tmp/goss-advisory-results.json /tmp/trivy-report.json

echo "--- Truncating logs and shell history"
find /var/log -type f -exec truncate -s 0 {} \; 2>/dev/null || true
rm -f /var/log/wtmp /var/log/btmp /var/log/lastlog
rm -f /root/.bash_history
for home in /home/*; do
  rm -f "${home}/.bash_history"
done
unset HISTFILE

echo "--- Verifying no SSM registration state is baked in"
# If the build instance ever registered with SSM, its registration would
# be inherited by every instance from this AMI and they would all appear
# as the same managed node.
rm -rf /var/lib/amazon/ssm/Vault/Store/RegistrationKey \
  /var/lib/amazon/ssm/registration \
  /var/lib/amazon/ssm/ipc 2>/dev/null || true

echo "--- Stopping sshd (listener closes; this connection survives)"
systemctl stop sshd.socket 2>/dev/null || true
systemctl stop sshd 2>/dev/null || true

echo "Cleanup complete."
