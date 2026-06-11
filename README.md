# Proof-gated solvency attestation on Solana

A Solana program that verifies a zero-knowledge proof via CPI and, on success, writes a
trusted on-chain **attestation** other programs can read. The proof shows that a committed set
of balances sums to at least a threshold — without ever revealing the balances.

```
client/prover            solvency-proof program            verifier.so (Sunspot/gnark)
─────────────            ──────────────────────            ───────────────────────────
 build proof  ──submit──▶ attest_solvency
 (Noir/Groth16)          │ 1. pin verifier program id (VERIFIER_ID)
                         │ 2. assemble [proof || public_witness]
                         │ 3. CPI ──────────────────────────▶ verify Groth16
                         │ 4. CPI Ok/Err  ◀───────────────────
                         │ 5. on success: write attestation PDA
                         ▼
                   SolvencyAttestation PDA  ◀── other programs read & trust
```

This is the pattern real ZK-on-Solana integrations need: **a proof gating a stateful on-chain
action**, not just a verifier called in isolation.

## What it proves (and what it doesn't)

The circuit (`circuit/src/main.nr`, fixed `N = 4`) proves:

- `Poseidon2(balances) == commitment` — the proof is bound to a **specific committed set**.
- `sum(balances) >= threshold`.

> **Honest caveat.** This is *provable computation*, not *provable solvency*. It shows the
> provided balances clear the threshold; it does **not** prove the balances are real or that the
> set is complete (no omitted liabilities, no invented assets). The commitment binds the proof to
> a specific set — it does not make that set true. See the provenance roadmap below.

## Layout

| Path | What |
|------|------|
| `circuit/` | Noir circuit + Sunspot proving pipeline (`setup.sh`, `prove.sh`) |
| `solvency-proof/` | Anchor program with the `attest_solvency` instruction |
| `scripts/` | `deploy_and_verify.sh` end-to-end runner + `attest_client.mjs` |

The on-chain program:

- `programs/.../instructions/solvency.rs` — assembles `[proof || public_witness]` in gnark format
  and CPIs the verifier; a clean return means the proof is valid, then it writes the PDA.
- `state.rs` — `SolvencyAttestation { commitment, threshold, verified, slot }`.
- `constants.rs` — `VERIFIER_ID`, the **pinned** verifier program id.

## Prerequisites

`nargo` (Noir), `go`, `solana` CLI + `cargo build-sbf`, `surfpool`, `node` + `npm`.

## Run it end to end

```bash
# 1. Build the Sunspot toolchain (one time)
cd circuit && ./setup.sh

# 2. Execute the circuit, prove, and build the Solana verifier .so
./prove.sh
# → circuit/target/{circuit.proof, circuit.pw, circuit.so, circuit-keypair.json}

# 3. Deploy both programs to a local surfpool validator and submit a real proof
cd ../scripts && ./deploy_and_verify.sh
```

A green run deploys the verifier + `solvency-proof`, sends `attest_solvency` with the real proof,
and reads back the attestation PDA showing `verified: true`.

Circuit tests (passing fixture, insolvent fixture, wrong commitment) run with:

```bash
cd circuit && nargo test
```

## Integration security

Two checks separate a real proof-gate from a trivially bypassable demo:

1. **Pin the verifier program id.** Verifying *a* proof with *some* program proves nothing if the
   program is attacker-chosen. The verifier account is constrained to a hard-coded `VERIFIER_ID`
   and required `executable` (`instructions/solvency.rs`).
2. **Verify the proof proves the *right* statement.** A valid Groth16 proof for the wrong public
   inputs is still a valid proof. The program must check `threshold`/`commitment` against its
   intent before trusting CPI success. *(Status: the threshold/commitment are written to the
   attestation as-supplied; an intent check against business-required values is not yet enforced —
   see status below.)*

## Status

Built and green:

- [x] Noir circuit with commitment binding + sum-≥-threshold; passing / failing / bad-commitment tests.
- [x] `attest_solvency` CPIs the pinned verifier and writes the attestation PDA on a valid proof.
- [x] Security check 1 — wrong verifier program id is rejected (pinned `VERIFIER_ID`, `executable`).
- [x] End-to-end script: prove → deploy → submit → attestation written.

Not yet done (tracked against the v2 scope):

- [ ] Security check 2 — reject a valid proof whose `threshold` doesn't match business intent.
- [ ] Range-constrain each balance (`0 <= b < 2^64`) and document the sum-overflow bound — the
      circuit currently casts `Field → u64` without an explicit range check.
- [ ] A second instruction/program that **consumes** the attestation, proving it's usable downstream.
- [ ] Devnet run (current e2e targets a local surfpool validator).

## Provenance roadmap (not in this scope)

Strengthening *authenticity* is about binding the balances to an anchor the verifier already
trusts — **without** revealing the accounts. (Reading the accounts' real balances on-chain would
work too, but it requires putting the addresses in the transaction, making them and their balances
public; that defeats the privacy the proof exists to provide, so it is not pursued here.)

1. **Signed attestations** (recommended next) — a trusted source signs `(account, balance)` pairs;
   the *circuit* verifies the signatures, so the addresses never leave the prover. Provenance is
   rooted in the signer's key. Bridges to TLS-attestation / zkTLS. *Limit:* trust-by-delegation to
   the signer.
2. **Published Merkle root** — prove each balance is a leaf under a pre-published root of all
   accounts. Attacks the *completeness* gap (no omitted accounts) while keeping individual balances
   private. *Limit:* doesn't stop a dishonest root.
