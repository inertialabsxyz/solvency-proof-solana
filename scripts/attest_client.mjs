// Sends an `attest_solvency` transaction to a running validator (surfpool) using
// the real gnark proof + public witness produced by the circuit toolchain.
//
// Usage:
//   node attest_client.mjs <RPC_URL> <REPO_ROOT>
//
// Reads:
//   <root>/solvency-proof/target/idl/solvency_proof.json
//   <root>/circuit/target/circuit.proof   (388-byte Groth16 proof)
//   <root>/circuit/target/circuit.pw      (76-byte gnark public witness)
//   <root>/circuit/target/circuit-keypair.json (verifier program id)

import fs from "node:fs";
import path from "node:path";
import anchor from "@coral-xyz/anchor";
import {
  Connection,
  Keypair,
  PublicKey,
  ComputeBudgetProgram,
  SystemProgram,
  Transaction,
  sendAndConfirmTransaction,
} from "@solana/web3.js";

const RPC_URL = process.argv[2] ?? "http://127.0.0.1:8899";
const ROOT = process.argv[3] ?? path.resolve(import.meta.dirname, "..");

const GNARK_HEADER_LEN = 12;

const idlPath = path.join(ROOT, "solvency-proof/target/idl/solvency_proof.json");
const idl = JSON.parse(fs.readFileSync(idlPath, "utf8"));
const programId = new PublicKey(idl.address);

const proof = fs.readFileSync(path.join(ROOT, "circuit/target/circuit.proof"));
const pw = fs.readFileSync(path.join(ROOT, "circuit/target/circuit.pw"));

// Public witness layout: 12-byte gnark header, then [threshold:32][commitment:32].
const thresholdField = pw.subarray(GNARK_HEADER_LEN, GNARK_HEADER_LEN + 32);
const threshold = thresholdField.readUInt32BE(28); // low 4 bytes of the BE field
const commitment = Uint8Array.from(pw.subarray(GNARK_HEADER_LEN + 32, GNARK_HEADER_LEN + 64));

// Verifier program id = pubkey of the keypair its .so was deployed with.
const verifierKp = loadKeypair(path.join(ROOT, "circuit/target/circuit-keypair.json"));
const verifierId = verifierKp.publicKey;

const payer = loadKeypair(path.join(process.env.HOME, ".config/solana/id.json"));

const connection = new Connection(RPC_URL, "confirmed");
const wallet = new anchor.Wallet(payer);
const provider = new anchor.AnchorProvider(connection, wallet, { commitment: "confirmed" });
const program = new anchor.Program(idl, provider);

const [solvencyPda] = PublicKey.findProgramAddressSync(
  [Buffer.from("solvency")],
  programId,
);

console.log("RPC:           ", RPC_URL);
console.log("program:       ", programId.toBase58());
console.log("verifier:      ", verifierId.toBase58());
console.log("payer:         ", payer.publicKey.toBase58());
console.log("solvency PDA:  ", solvencyPda.toBase58());
console.log("threshold:     ", threshold);
console.log("commitment:    ", Buffer.from(commitment).toString("hex"));
console.log("proof bytes:   ", proof.length);

// The attestation PDA is created with `init` (one-shot). If it already exists
// from a previous run, re-sending would fail with "account already in use".
// Report the existing attestation and exit successfully instead.
const existing = await connection.getAccountInfo(solvencyPda);
if (existing) {
  const prior = await program.account.solvencyAttestation.fetch(solvencyPda);
  console.log("\nℹ️  attestation PDA already exists — skipping re-attest.");
  console.log("  verified:   ", prior.verified);
  console.log("  threshold:  ", prior.threshold);
  console.log("  slot:       ", prior.slot.toString());
  console.log("  commitment: ", Buffer.from(prior.commitment).toString("hex"));
  process.exit(prior.verified ? 0 : 1);
}

// Groth16/BN254 verification exceeds the default 200k CU budget.
const computeIx = ComputeBudgetProgram.setComputeUnitLimit({ units: 1_400_000 });

const attestIx = await program.methods
  .attestSolvency(Buffer.from(proof), threshold, Array.from(commitment))
  .accounts({
    signer: payer.publicKey,
    solvency: solvencyPda,
    verifier: verifierId,
    systemProgram: SystemProgram.programId,
  })
  .instruction();

const tx = new Transaction().add(computeIx, attestIx);
const sig = await sendAndConfirmTransaction(connection, tx, [payer], {
  commitment: "confirmed",
  skipPreflight: false,
});
console.log("\n✅ attest_solvency confirmed:", sig);

// Read back the attestation account.
const attestation = await program.account.solvencyAttestation.fetch(solvencyPda);
console.log("\nAttestation account:");
console.log("  verified:   ", attestation.verified);
console.log("  threshold:  ", attestation.threshold);
console.log("  slot:       ", attestation.slot.toString());
console.log("  commitment: ", Buffer.from(attestation.commitment).toString("hex"));

if (!attestation.verified) {
  console.error("\n❌ attestation.verified is false");
  process.exit(1);
}
console.log("\n🎉 proof verified on-chain and attestation recorded");

function loadKeypair(p) {
  const secret = Uint8Array.from(JSON.parse(fs.readFileSync(p, "utf8")));
  return Keypair.fromSecretKey(secret);
}
