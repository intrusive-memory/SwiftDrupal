#!/usr/bin/env bash
# Build, ad-hoc codesign (virtualization entitlement), fetch a kernel if
# needed, and run the Containerization runtime spike.
# See docs/spikes/01-containerization-runtime-spike.md.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

: "${SPIKE_HOME:=$HOME/Library/Application Support/swiftdrupal-spike}"
export SPIKE_HOME
mkdir -p "$SPIKE_HOME"

# 1. Kernel. Same Kata Containers kernel apple/containerization's
#    `make fetch-default-kernel` uses (and that `container system kernel set
#    --recommended` installs). Only the one vmlinux file is extracted.
KATA_VERSION="${KATA_VERSION:-3.17.0}"
KATA_URL="https://github.com/kata-containers/kata-containers/releases/download/${KATA_VERSION}/kata-static-${KATA_VERSION}-arm64.tar.xz"
kernel="${SPIKE_KERNEL:-$SPIKE_HOME/vmlinux-arm64}"
if [[ ! -f "$kernel" ]]; then
  echo "Fetching kernel from $KATA_URL (~290 MB tarball, one-time)" >&2
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fSsL -o "$tmp/kata.tar.xz" "$KATA_URL"
  tar -xJf "$tmp/kata.tar.xz" -C "$tmp" ./opt/kata/share/kata-containers/
  cp -L "$tmp/opt/kata/share/kata-containers/vmlinux.container" "$kernel"
  rm -rf "$tmp"
fi

# 2. Build and sign. Virtualization.framework refuses to create a VM unless the
#    calling binary carries com.apple.security.virtualization; an ad-hoc
#    signature is enough (no Developer ID / provisioning profile needed).
# Release by default: in a debug build EXT4Unpacker takes ~160 s for the
# ddev-webserver layer vs ~2 s in release.
config="${SPIKE_CONFIG:-release}"
swift build -c "$config" --product container-spike >&2
bin="$(swift build -c "$config" --show-bin-path)/container-spike"
codesign --force --sign - --entitlements scripts/container-spike.entitlements "$bin"

# 3. Run. JSON report on stdout (also saved to $SPIKE_HOME/last-report.json),
#    progress + timings on stderr.
exec "$bin" "$@"
