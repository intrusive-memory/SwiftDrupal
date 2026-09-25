#!/usr/bin/env bash
# Build a release `drupal`, ad-hoc sign it with the virtualization
# entitlement (swift build strips signatures, and Virtualization.framework
# refuses unsigned callers), and install it as a copy — not a symlink — so the
# resolver LaunchAgent's recorded path stays valid across rebuilds.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

dest="${DRUPAL_INSTALL_DIR:-$HOME/.local/bin}/drupal"

swift build -c release --product drupal >&2
bin="$(swift build -c release --show-bin-path)/drupal"
codesign --force --sign - --entitlements scripts/drupal.entitlements "$bin"

mkdir -p "$(dirname "$dest")"
install -m 0755 "$bin" "$dest.new"
mv -f "$dest.new" "$dest"
echo "installed $dest" >&2

# A running responder still has the old binary mapped; restart it.
label=dev.swiftdrupal.resolver
if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
  launchctl kickstart -k "gui/$(id -u)/$label"
  echo "restarted $label" >&2
fi
