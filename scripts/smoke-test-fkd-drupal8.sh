#!/usr/bin/env bash
#
# End-to-end smoke test: proves the `drupal` binary can host a real Drupal 11
# site (not a synthetic one), against the `fkd-drupal8` fixture described in
# EXECUTION_PLAN.md's "Acceptance Fixture" section.
#
# NOT RUN DURING THE MISSION THAT WROTE THIS SCRIPT (EXECUTION_PLAN.md
# Resolved OQ-6): the user runs it on another machine that has the fixture
# checked out and the `drupal` service already installed. This script only
# asserts and reports; it does not `git clone`, `terminus backup:get`, or
# install anything itself.
#
# Step order note: EXECUTION_PLAN.md's Task 2 lists `init` -> `import-db` ->
# `start`, written before the host-service model (OQ-4) existed. Under that
# model the database container must already be RUNNING before `import-db`
# can stream into it, so this script runs `start` BEFORE `import-db`:
#   init -> start -> import-db -> status -> (HTTP check) -> stop -> delete
#
# Usage:
#   scripts/smoke-test-fkd-drupal8.sh [options]
#
# Options:
#   --project <path>   Drupal codebase root. Default: $HOME/Projects/caffrey/fkd-drupal8
#   --dump <path>       SQL dump to import (.sql or .sql.gz). Default:
#                        <project>/dbbackup/fkd-drupal8_live_2026-09-11T17-57-07_UTC_database.sql.gz
#   --drupal <binary>   Path to (or name of) the drupal binary. Default: `drupal` on PATH.
#   --keep-data         Pass --keep-data through to the final `delete` step.
#   --help              Show this help and exit.
#
# No path on this machine is hardcoded beyond the defaults above, all of
# which are overridable.
#
# Exit status: 0 when every step PASSes. On the first failing step, this
# script still attempts `stop` (best-effort cleanup) and then exits non-zero,
# printing the name of the step that failed.

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

PROJECT_PATH="${HOME}/Projects/caffrey/fkd-drupal8"
DUMP_PATH=""
DRUPAL_BIN="drupal"
KEEP_DATA=false

usage() {
  cat <<'EOF'
Usage: smoke-test-fkd-drupal8.sh [options]

Options:
  --project <path>   Drupal codebase root.
                      Default: $HOME/Projects/caffrey/fkd-drupal8
  --dump <path>       SQL dump to import (.sql or .sql.gz).
                      Default: <project>/dbbackup/fkd-drupal8_live_2026-09-11T17-57-07_UTC_database.sql.gz
  --drupal <binary>   Path to (or name of) the drupal binary.
                      Default: `drupal` resolved from PATH.
  --keep-data         Pass --keep-data through to the final `delete` step,
                      keeping the imported database's data directory.
  --help              Show this help and exit.

Steps run, in order: init, start, import-db, status, an HTTP check, stop,
delete. See the script header comment for why `start` runs before
`import-db` (a reordering versus EXECUTION_PLAN.md's original task text).

This script is not executed as part of writing it (EXECUTION_PLAN.md
Resolved OQ-6) — the operator runs it by hand on a prepared machine.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project)
      PROJECT_PATH="$2"
      shift 2
      ;;
    --dump)
      DUMP_PATH="$2"
      shift 2
      ;;
    --drupal)
      DRUPAL_BIN="$2"
      shift 2
      ;;
    --keep-data)
      KEEP_DATA=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

if [[ -z "$DUMP_PATH" ]]; then
  DUMP_PATH="${PROJECT_PATH}/dbbackup/fkd-drupal8_live_2026-09-11T17-57-07_UTC_database.sql.gz"
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

FAILED_STEP=""

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; }

# Records and prints a step failure. Deliberately does NOT `return 1` itself
# (that would trip `set -e` at the call site, which is a bare statement, not
# a condition, and would abort the whole script before its caller's own
# `return 1` runs) -- every call site follows this with its own `return 1`.
die_step() {
  local step="$1"
  shift
  fail "$step: $*"
  FAILED_STEP="$step"
}

# Resolves DRUPAL_BIN to an absolute path when it is a bare command on PATH.
resolve_drupal_bin() {
  if [[ "$DRUPAL_BIN" != */* ]]; then
    local resolved
    resolved="$(command -v "$DRUPAL_BIN" 2>/dev/null || true)"
    if [[ -n "$resolved" ]]; then
      DRUPAL_BIN="$resolved"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------

preflight() {
  echo "==> Preflight checks"

  local major
  major="$(sw_vers -productVersion | cut -d. -f1)"
  if [[ "$major" -ge 26 ]]; then
    pass "macOS $major (>= 26)"
  else
    die_step "preflight" "macOS $major detected; this tool requires macOS 26+"
    return 1
  fi

  local arch
  arch="$(uname -m)"
  if [[ "$arch" == "arm64" ]]; then
    pass "Apple Silicon ($arch)"
  else
    die_step "preflight" "architecture $arch detected; this tool requires Apple Silicon (arm64)"
    return 1
  fi

  resolve_drupal_bin
  if [[ -x "$DRUPAL_BIN" ]]; then
    pass "drupal binary present: $DRUPAL_BIN"
  else
    die_step "preflight" "drupal binary not found or not executable: $DRUPAL_BIN (pass --drupal /path/to/drupal)"
    return 1
  fi

  if codesign -d --entitlements - "$DRUPAL_BIN" 2>/dev/null | grep -q "com.apple.security.virtualization"; then
    pass "drupal binary carries the com.apple.security.virtualization entitlement"
  else
    die_step "preflight" "drupal binary at $DRUPAL_BIN is missing the com.apple.security.virtualization entitlement; sign it: codesign --force --sign - --entitlements drupal.entitlements $DRUPAL_BIN"
    return 1
  fi

  local kernel_path="${HOME}/Library/Application Support/com.apple.container/kernels/default.kernel-arm64"
  if [[ -f "$kernel_path" ]]; then
    pass "kernel present: $kernel_path"
  else
    die_step "preflight" "kernel not found at $kernel_path; install Apple's container CLI and run: container system start --enable-kernel-install (or: container system kernel set --recommended)"
    return 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    die_step "preflight" "jq is required but not found on PATH"
    return 1
  fi
  pass "jq is available"

  local status_json
  if ! status_json="$("$DRUPAL_BIN" service status --json 2>/dev/null)"; then
    die_step "preflight" "drupal service status --json failed to run"
    return 1
  fi
  if echo "$status_json" | jq -e '.socketReachable == true' >/dev/null 2>&1; then
    pass "drupal service socket is reachable"
  else
    die_step "preflight" "drupal service is not reachable; remedy: $DRUPAL_BIN service install"
    return 1
  fi

  if [[ -d "$PROJECT_PATH" ]]; then
    pass "project directory exists: $PROJECT_PATH"
  else
    die_step "preflight" "project directory not found: $PROJECT_PATH (pass --project /path/to/fkd-drupal8)"
    return 1
  fi

  if [[ -f "$DUMP_PATH" ]]; then
    pass "database dump exists: $DUMP_PATH"
  else
    die_step "preflight" "database dump not found: $DUMP_PATH (pass --dump /path/to/dump.sql.gz)"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------

step_init() {
  echo "==> Step: init"
  if [[ -f "${PROJECT_PATH}/.drupal/config.yaml" ]]; then
    pass "init: .drupal/config.yaml already exists in $PROJECT_PATH, skipping init"
    return 0
  fi

  local out
  if ! out="$(cd "$PROJECT_PATH" && "$DRUPAL_BIN" init --json)"; then
    die_step "init" "drupal init exited non-zero"
    return 1
  fi
  if echo "$out" | jq -e '.resolved.hostname and .resolved.name and .resolved.configPath' >/dev/null 2>&1; then
    pass "init: wrote config for $(echo "$out" | jq -r '.resolved.name'), hostname $(echo "$out" | jq -r '.resolved.hostname')"
  else
    die_step "init" "unexpected JSON shape: $out"
    return 1
  fi
}

step_start() {
  echo "==> Step: start"
  local out
  if ! out="$(cd "$PROJECT_PATH" && "$DRUPAL_BIN" start --json)"; then
    die_step "start" "drupal start exited non-zero"
    return 1
  fi
  if echo "$out" | jq -e '.state == "running" and (.containers | length) == 2' >/dev/null 2>&1; then
    pass "start: project running, 2 containers, url $(echo "$out" | jq -r '.url')"
  else
    die_step "start" "unexpected JSON shape or state: $out"
    return 1
  fi
}

step_import_db() {
  echo "==> Step: import-db"
  local out
  if ! out="$(cd "$PROJECT_PATH" && "$DRUPAL_BIN" import-db "$DUMP_PATH" --json)"; then
    die_step "import-db" "drupal import-db exited non-zero"
    return 1
  fi
  if echo "$out" | jq -e '.operation == "import" and .success == true' >/dev/null 2>&1; then
    pass "import-db: $(echo "$out" | jq -r '.bytesProcessed') bytes processed into $(echo "$out" | jq -r '.containerId')"
  else
    die_step "import-db" "unexpected JSON shape or failure: $out"
    return 1
  fi
}

STATUS_HOSTNAME=""

step_status() {
  echo "==> Step: status"
  local out
  if ! out="$(cd "$PROJECT_PATH" && "$DRUPAL_BIN" status --json)"; then
    die_step "status" "drupal status exited non-zero"
    return 1
  fi
  if echo "$out" | jq -e '.state == "running" and .hostname and .url' >/dev/null 2>&1; then
    STATUS_HOSTNAME="$(echo "$out" | jq -r '.hostname')"
    pass "status: running, hostname $STATUS_HOSTNAME"
  else
    die_step "status" "unexpected JSON shape or state: $out"
    return 1
  fi
}

step_http_check() {
  echo "==> Step: http-check"
  if [[ -z "$STATUS_HOSTNAME" ]]; then
    die_step "http-check" "no hostname captured from the status step"
    return 1
  fi
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' "http://${STATUS_HOSTNAME}/" || echo "000")"
  case "$code" in
    200|302|303)
      pass "http-check: http://${STATUS_HOSTNAME}/ returned $code"
      ;;
    *)
      die_step "http-check" "http://${STATUS_HOSTNAME}/ returned $code (expected 200, 302, or 303)"
      return 1
      ;;
  esac
}

step_stop() {
  echo "==> Step: stop"
  local out
  if ! out="$(cd "$PROJECT_PATH" && "$DRUPAL_BIN" stop --json)"; then
    die_step "stop" "drupal stop exited non-zero"
    return 1
  fi
  if echo "$out" | jq -e '.state == "stopped"' >/dev/null 2>&1; then
    pass "stop: project stopped"
  else
    die_step "stop" "unexpected JSON shape or state: $out"
    return 1
  fi
}

step_delete() {
  echo "==> Step: delete"
  local args=(delete --json)
  if [[ "$KEEP_DATA" == true ]]; then
    args=(delete --keep-data --json)
  fi
  local out
  if ! out="$(cd "$PROJECT_PATH" && "$DRUPAL_BIN" "${args[@]}")"; then
    die_step "delete" "drupal delete exited non-zero"
    return 1
  fi
  if echo "$out" | jq -e '.state == "stopped" and (.removedDataDirectories | type == "array")' >/dev/null 2>&1; then
    local removed_count
    removed_count="$(echo "$out" | jq '.removedDataDirectories | length')"
    if [[ "$KEEP_DATA" == true ]]; then
      pass "delete: containers removed, database data kept ($removed_count directories removed)"
    else
      pass "delete: containers and database data removed ($removed_count directories removed)"
    fi
  else
    die_step "delete" "unexpected JSON shape: $out"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  preflight

  local overall_status=0

  if ! step_init; then
    overall_status=1
  elif ! step_start; then
    overall_status=1
  elif ! step_import_db; then
    overall_status=1
  elif ! step_status; then
    overall_status=1
  elif ! step_http_check; then
    overall_status=1
  fi

  # Best-effort cleanup: always try to stop, even after an earlier failure,
  # so a failed run doesn't leave containers running.
  if ! step_stop; then
    overall_status=1
    [[ -z "$FAILED_STEP" ]] && FAILED_STEP="stop"
  fi

  if [[ $overall_status -eq 0 ]]; then
    if ! step_delete; then
      overall_status=1
    fi
  else
    echo "==> Skipping delete: an earlier step failed (see below)" >&2
  fi

  if [[ $overall_status -eq 0 ]]; then
    echo "ALL STEPS PASSED"
    exit 0
  else
    echo "SMOKE TEST FAILED at step: ${FAILED_STEP:-unknown}" >&2
    exit 1
  fi
}

main "$@"
