#!/usr/bin/env bash
#
# Deploy the solvency-proof program and the gnark verifier to a local surfpool
# validator, then send an attest_solvency transaction that verifies the real
# proof on-chain and records the attestation.
#
# Prereqs: solana CLI, cargo build-sbf, surfpool, node, npm. Run from anywhere.
set -euo pipefail

# --- Paths (relative to this script, not the caller) -------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROGRAM_DIR="$ROOT/solvency-proof"
PROGRAM_SO="$PROGRAM_DIR/target/deploy/solvency_proof.so"
PROGRAM_KP="$PROGRAM_DIR/target/deploy/solvency_proof-keypair.json"
VERIFIER_SO="$ROOT/circuit/target/circuit.so"
VERIFIER_KP="$ROOT/circuit/target/circuit-keypair.json"

RPC_URL="${RPC_URL:-http://127.0.0.1:8899}"
PAYER_KP="${PAYER_KP:-$HOME/.config/solana/id.json}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- Sanity checks -----------------------------------------------------------
for bin in solana cargo surfpool node npm; do
  command -v "$bin" >/dev/null 2>&1 || die "missing required tool: $bin"
done
[[ -f "$VERIFIER_SO" ]] || die "verifier .so not found: $VERIFIER_SO (build the circuit first)"
[[ -f "$VERIFIER_KP" ]] || die "verifier keypair not found: $VERIFIER_KP"
[[ -f "$PAYER_KP"   ]] || die "payer keypair not found: $PAYER_KP"

# --- 1. Build the program (sbf) + IDL ---------------------------------------
log "Building solvency-proof program (sbf) ..."
( cd "$PROGRAM_DIR" && cargo build-sbf )
# build-sbf writes under target/sbpf-...; mirror into target/deploy for deploy.
SBF_SO="$(find "$PROGRAM_DIR/target" -path '*release/solvency_proof.so' | head -n1)"
[[ -n "$SBF_SO" ]] || die "built program .so not found"
mkdir -p "$(dirname "$PROGRAM_SO")"
cp "$SBF_SO" "$PROGRAM_SO"

log "Regenerating IDL ..."
( cd "$PROGRAM_DIR" && anchor idl build -o "$PROGRAM_DIR/target/idl/solvency_proof.json" 2>/dev/null ) \
  || log "anchor idl build skipped (using existing IDL)"

# --- 2. Start surfpool if not already running -------------------------------
STARTED_SURFPOOL=""
if curl -s "$RPC_URL" -X POST -H 'content-type: application/json' \
     -d '{"jsonrpc":"2.0","id":1,"method":"getHealth"}' 2>/dev/null | grep -q '"ok"'; then
  log "surfpool already running at $RPC_URL"
else
  log "Starting surfpool ..."
  surfpool start --no-tui >/tmp/surfpool.log 2>&1 &
  STARTED_SURFPOOL=$!
  log "Waiting for RPC at $RPC_URL ..."
  for _ in $(seq 1 60); do
    if curl -s "$RPC_URL" -X POST -H 'content-type: application/json' \
         -d '{"jsonrpc":"2.0","id":1,"method":"getHealth"}' 2>/dev/null | grep -q '"ok"'; then
      break
    fi
    sleep 1
  done
  curl -s "$RPC_URL" -X POST -H 'content-type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"getHealth"}' 2>/dev/null | grep -q '"ok"' \
    || die "surfpool did not become healthy (see /tmp/surfpool.log)"
fi

cleanup() {
  if [[ -n "$STARTED_SURFPOOL" ]]; then
    log "Stopping surfpool (pid $STARTED_SURFPOOL) ..."
    kill "$STARTED_SURFPOOL" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# --- 3. Fund the payer -------------------------------------------------------
PAYER_PUBKEY="$(solana-keygen pubkey "$PAYER_KP")"
log "Airdropping to payer $PAYER_PUBKEY ..."
solana airdrop 100 "$PAYER_PUBKEY" --url "$RPC_URL" >/dev/null 2>&1 || \
  log "airdrop returned non-zero (may already be funded)"

# --- 4. Deploy both programs -------------------------------------------------
log "Deploying verifier ($(solana-keygen pubkey "$VERIFIER_KP")) ..."
solana program deploy "$VERIFIER_SO" \
  --program-id "$VERIFIER_KP" \
  --keypair "$PAYER_KP" \
  --url "$RPC_URL"

log "Deploying solvency-proof ($(solana-keygen pubkey "$PROGRAM_KP")) ..."
solana program deploy "$PROGRAM_SO" \
  --program-id "$PROGRAM_KP" \
  --keypair "$PAYER_KP" \
  --url "$RPC_URL"

# --- 5. Install JS deps (once) ----------------------------------------------
if [[ ! -d "$SCRIPT_DIR/node_modules/@coral-xyz/anchor" ]]; then
  log "Installing JS client deps ..."
  ( cd "$SCRIPT_DIR" && npm install --silent @coral-xyz/anchor @solana/web3.js )
fi

# --- 6. Send the attest_solvency transaction --------------------------------
log "Sending attest_solvency transaction ..."
node "$SCRIPT_DIR/attest_client.mjs" "$RPC_URL" "$ROOT"

log "Done."
