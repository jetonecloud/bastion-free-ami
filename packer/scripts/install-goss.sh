#!/usr/bin/env bash
# Install the pinned Goss release on the build instance.
#
# The archive is verified against a checksum passed in from
# packer/variables.pkr.hcl BEFORE it is unpacked or executed. A download
# that does not match is a hard failure: this binary decides whether the
# AMI is publishable, so running an unverified one would defeat the gate.
set -euo pipefail

: "${GOSS_VERSION:?GOSS_VERSION must be set}"
: "${GOSS_ARCH:?GOSS_ARCH must be set (x86_64 or arm64)}"
: "${GOSS_CHECKSUM:?GOSS_CHECKSUM must be set}"

ARCHIVE="goss_${GOSS_VERSION}_linux_${GOSS_ARCH}.tar.gz"
URL="https://github.com/goss-org/goss/releases/download/v${GOSS_VERSION}/${ARCHIVE}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

echo "Downloading ${URL}"
curl -fsSL --retry 3 --retry-delay 2 -o "${WORKDIR}/${ARCHIVE}" "${URL}"

echo "Verifying SHA256"
echo "${GOSS_CHECKSUM}  ${WORKDIR}/${ARCHIVE}" | sha256sum -c -

tar -xzf "${WORKDIR}/${ARCHIVE}" -C "${WORKDIR}"
install -o root -g root -m 0755 "${WORKDIR}/goss" /usr/local/bin/goss

/usr/local/bin/goss --version
