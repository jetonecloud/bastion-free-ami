#!/usr/bin/env bash
# Install the pinned Trivy release on the build instance, verifying the
# archive checksum before unpacking. Same reasoning as install-goss.sh.
set -euo pipefail

: "${TRIVY_VERSION:?TRIVY_VERSION must be set}"
: "${TRIVY_ARCH:?TRIVY_ARCH must be set (Linux-64bit or Linux-ARM64)}"
: "${TRIVY_CHECKSUM:?TRIVY_CHECKSUM must be set}"

ARCHIVE="trivy_${TRIVY_VERSION}_${TRIVY_ARCH}.tar.gz"
URL="https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/${ARCHIVE}"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

echo "Downloading ${URL}"
curl -fsSL --retry 3 --retry-delay 2 -o "${WORKDIR}/${ARCHIVE}" "${URL}"

echo "Verifying SHA256"
echo "${TRIVY_CHECKSUM}  ${WORKDIR}/${ARCHIVE}" | sha256sum -c -

tar -xzf "${WORKDIR}/${ARCHIVE}" -C "${WORKDIR}"
install -o root -g root -m 0755 "${WORKDIR}/trivy" /usr/local/bin/trivy

/usr/local/bin/trivy --version
