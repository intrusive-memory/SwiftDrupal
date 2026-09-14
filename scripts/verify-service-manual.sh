#!/usr/bin/env bash
# Manual verification for the launchd-managed `drupal service` (Sortie 8).
#
# NOT run in CI and NOT run by automated agents: it installs a real per-user
# LaunchAgent (~/Library/LaunchAgents), bootstraps it with launchctl, and writes
# /etc/resolver/drupal (macOS prompts for an administrator password once).
#
# Usage:
#   scripts/verify-service-manual.sh /absolute/path/to/drupal [--uninstall]
#
# The binary must be at a stable absolute path and signed with the
# com.apple.security.virtualization entitlement (containers only; the DNS and
# socket checks below work without it). Moving or rebuilding the binary
# requires running `drupal service install` again.
#
# Pass criteria (all must print PASS):
#   1. `launchctl print gui/$UID/com.intrusive-memory.swiftdrupal.service` shows `state = running`.
#   2. `dig @127.0.0.1 -p 1053 probe.drupal` gets an answer (A 127.0.0.1).
#   3. `drupal service status --json` reports "socketReachable" : true.
#   4. With the resolver registered, the system resolver answers probe.drupal too
#      (informational: a failure here is the known macOS 26 /etc/resolver
#      custom-TLD regression, handled at runtime by the /etc/hosts fallback).

set -uo pipefail

LABEL="com.intrusive-memory.swiftdrupal.service"
DRUPAL="${1:-}"
if [[ -z "$DRUPAL" || "$DRUPAL" != /* || ! -x "$DRUPAL" ]]; then
  echo "usage: $0 /absolute/path/to/drupal [--uninstall]" >&2
  exit 2
fi

failures=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }

echo "==> drupal service install"
"$DRUPAL" service install --json || { echo "install failed" >&2; exit 1; }

# Give launchd a moment to spawn the agent and the agent to bind its sockets.
for _ in $(seq 1 20); do
  launchctl print "gui/$UID/$LABEL" 2>/dev/null | grep -q "state = running" && break
  sleep 0.5
done

echo "==> launchctl print gui/$UID/$LABEL"
if launchctl print "gui/$UID/$LABEL" | tee /dev/stderr | grep -q "state = running"; then
  pass "agent is running"
else
  fail "agent is not running (see ~/Library/Logs/SwiftDrupal/service.log)"
fi

echo "==> dig @127.0.0.1 -p 1053 probe.drupal"
answer="$(dig @127.0.0.1 -p 1053 probe.drupal A +short +time=2 +tries=2)"
if [[ "$answer" == "127.0.0.1" ]]; then
  pass "responder answered probe.drupal -> $answer"
else
  fail "no answer from responder (got: '${answer}')"
fi

echo "==> drupal service status --json"
status="$("$DRUPAL" service status --json)"
echo "$status"
if echo "$status" | grep -q '"socketReachable" : true'; then
  pass "service socket reachable"
else
  fail "service socket not reachable"
fi

echo "==> system resolver (informational)"
if dscacheutil -q host -a name probe.drupal | grep -q "127.0.0.1"; then
  echo "INFO: /etc/resolver/drupal is honoured by the system resolver"
else
  echo "INFO: system resolver did not answer probe.drupal (macOS 26 regression?); /etc/hosts fallback will be used"
fi

if [[ "${2:-}" == "--uninstall" ]]; then
  echo "==> drupal service uninstall"
  "$DRUPAL" service uninstall --json
fi

if [[ $failures -eq 0 ]]; then
  echo "ALL CHECKS PASSED"
else
  echo "$failures CHECK(S) FAILED"
  exit 1
fi
