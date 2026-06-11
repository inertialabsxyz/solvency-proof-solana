#!/usr/bin/env bash
#
# Full proving pipeline: execute the Noir circuit, then compile/setup/prove with
# sunspot and build the Solana gnark verifier program. Verifies the proof at the
# end so a green run means the artifacts are good.
#
# Outputs (all under target/):
#   circuit.json  compiled ACIR        circuit.pk/.vk  proving/verifying keys
#   circuit.gz    witness              circuit.proof   388-byte Groth16 proof
#   circuit.ccs   constraint system    circuit.pw      76-byte public witness
#   circuit.so    Solana verifier      circuit-keypair.json  verifier program id
#
# Env knobs: SKIP_DEPLOY=1 to stop before building the verifier .so.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

SUNSPOT_BIN="$SCRIPT_DIR/sunspot/go/sunspot"
export GNARK_VERIFIER_BIN="$SCRIPT_DIR/sunspot/gnark-solana/crates/verifier-bin"
TARGET="$SCRIPT_DIR/target"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v nargo >/dev/null 2>&1 || die "nargo is required (https://noir-lang.org)"
[[ -x "$SUNSPOT_BIN" ]] || die "sunspot not built — run ./setup.sh first"

sunspot() { "$SUNSPOT_BIN" "$@"; }

# --- 1. Execute the Noir circuit (compile ACIR + generate witness) -----------
log "Executing Noir circuit (nargo execute) ..."
nargo execute
[[ -f "$TARGET/circuit.json" ]] || die "missing $TARGET/circuit.json after nargo execute"
[[ -f "$TARGET/circuit.gz"   ]] || die "missing $TARGET/circuit.gz (witness) after nargo execute"

# --- 2. Compile ACIR -> CCS --------------------------------------------------
log "Compiling ACIR to constraint system (sunspot compile) ..."
sunspot compile "$TARGET/circuit.json"

# --- 3. Trusted setup: proving + verifying keys ------------------------------
log "Generating proving/verifying keys (sunspot setup) ..."
sunspot setup "$TARGET/circuit.ccs"

# --- 4. Prove ----------------------------------------------------------------
log "Creating Groth16 proof (sunspot prove) ..."
sunspot prove \
  "$TARGET/circuit.json" \
  "$TARGET/circuit.gz" \
  "$TARGET/circuit.ccs" \
  "$TARGET/circuit.pk"

# --- 5. Verify the proof off-chain (sanity gate) -----------------------------
log "Verifying proof (sunspot verify) ..."
sunspot verify "$TARGET/circuit.vk" "$TARGET/circuit.proof" "$TARGET/circuit.pw"

# --- 6. Build the Solana verifier program ------------------------------------
if [[ "${SKIP_DEPLOY:-0}" == "1" ]]; then
  log "SKIP_DEPLOY=1 set — skipping verifier build."
else
  # sunspot deploy only generates a new keypair when target/circuit-keypair.json
  # is absent (e.g. after a clean), which would change the verifier program id
  # and break the on-chain `address = VERIFIER_ID` constraint. Keep a stable
  # copy outside target/ and restore it before deploy so the id is deterministic.
  STABLE_KP="$SCRIPT_DIR/verifier-keypair.json"
  if [[ -f "$STABLE_KP" ]]; then
    log "Restoring stable verifier keypair ..."
    cp "$STABLE_KP" "$TARGET/circuit-keypair.json"
  fi

  log "Building Solana verifier program (sunspot deploy) ..."
  sunspot deploy "$TARGET/circuit.vk"
  [[ -f "$TARGET/circuit.so" ]] || die "verifier .so not produced"

  # Persist whatever keypair was used so future runs stay on the same id.
  cp "$TARGET/circuit-keypair.json" "$STABLE_KP"

  VERIFIER_ID=""
  if command -v solana-keygen >/dev/null 2>&1; then
    VERIFIER_ID="$(solana-keygen pubkey "$TARGET/circuit-keypair.json")"
  fi
  log "Verifier program:    $TARGET/circuit.so"
  log "Verifier program id: ${VERIFIER_ID:-(see $TARGET/circuit-keypair.json)}"

  # Warn loudly if the program's hardcoded VERIFIER_ID no longer matches.
  CONST_FILE="$SCRIPT_DIR/../solvency-proof/programs/solvency-proof/src/constants.rs"
  if [[ -n "$VERIFIER_ID" && -f "$CONST_FILE" ]] \
     && ! grep -q "$VERIFIER_ID" "$CONST_FILE"; then
    printf '\033[1;33mwarning:\033[0m VERIFIER_ID in %s does not match the deployed id %s\n' \
      "$CONST_FILE" "$VERIFIER_ID" >&2
    printf '         Update the constant and rebuild the program before deploying.\n' >&2
  fi
fi

log "Done — proof and artifacts in $TARGET/"
