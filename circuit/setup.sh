#!/usr/bin/env bash
#
# One-time setup: clone the sunspot toolchain and build its CLI.
# Idempotent — re-running updates the checkout and rebuilds.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUNSPOT_REPO="${SUNSPOT_REPO:-git@github.com:reilabs/sunspot.git}"
SUNSPOT_DIR="$SCRIPT_DIR/sunspot"
SUNSPOT_BIN="$SUNSPOT_DIR/go/sunspot"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v git >/dev/null 2>&1 || die "git is required"
command -v go  >/dev/null 2>&1 || die "go is required (https://go.dev/dl/)"

# --- Clone or update sunspot -------------------------------------------------
if [[ -d "$SUNSPOT_DIR/.git" ]]; then
  log "sunspot already cloned — pulling latest ..."
  git -C "$SUNSPOT_DIR" pull --ff-only || log "pull skipped (local changes or offline)"
else
  log "Cloning sunspot from $SUNSPOT_REPO ..."
  git clone "$SUNSPOT_REPO" "$SUNSPOT_DIR"
fi

# --- Build the CLI -----------------------------------------------------------
log "Building sunspot CLI ..."
( cd "$SUNSPOT_DIR/go" && go build -o sunspot . )
[[ -x "$SUNSPOT_BIN" ]] || die "build did not produce $SUNSPOT_BIN"

log "Done. sunspot binary at: $SUNSPOT_BIN"
log "Run ./prove.sh next to generate a proof and verifier."
