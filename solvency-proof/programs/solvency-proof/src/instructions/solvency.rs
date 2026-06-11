use anchor_lang::prelude::*;
use anchor_lang::solana_program::{instruction::Instruction, program::invoke};

use crate::{SolvencyAttestation, SOLVENCY, VERIFIER_ID};

#[derive(Accounts)]
pub struct AttestSolvency<'info> {
    #[account(mut)]
    pub signer: Signer<'info>,

    #[account(
        init,
        payer = signer,
        space = 8 + SolvencyAttestation::INIT_SPACE,
        seeds = [SOLVENCY.as_bytes()],
        bump,
    )]
    pub solvency: Account<'info, SolvencyAttestation>,

    /// CHECK: The Verifier's contract address
    #[account(
        address = VERIFIER_ID,
        executable,
    )]
    pub verifier: UncheckedAccount<'info>,

    pub system_program: Program<'info, System>,
}

pub fn handler(
    ctx: Context<AttestSolvency>,
    proof: Vec<u8>,
    threshold: u32,
    commitment: [u8; 32],
) -> Result<()> {
    // Public witness in gnark format: a 12-byte header followed by one 32-byte
    // big-endian field element per public input. Order matches the circuit's
    // main(balances, threshold, commitment): [threshold, commitment].
    // Verified against circuit/target/circuit.pw, whose header is
    // 0x00000002_00000000_00000002 = [2 public, 0 private, count 2].
    const NR_INPUTS: u32 = 2;
    let mut witness = Vec::with_capacity(12 + (NR_INPUTS as usize) * 32);
    witness.extend_from_slice(&NR_INPUTS.to_be_bytes()); // nr public inputs
    witness.extend_from_slice(&0u32.to_be_bytes()); // nr private inputs (always 0)
    witness.extend_from_slice(&NR_INPUTS.to_be_bytes()); // vector entry count
    witness.extend_from_slice(&u32_to_be_field(threshold)); // input[0]: threshold
    witness.extend_from_slice(&commitment); // input[1]: commitment (32 BE bytes)

    // Verifier instruction data: [proof][public_witness]. The verifier splits
    // off the trailing 12 + NR_INPUTS*32 bytes as the witness; everything
    // before that is the proof.
    let mut data = Vec::with_capacity(proof.len() + witness.len());
    data.extend_from_slice(&proof);
    data.extend_from_slice(&witness);

    let verify_ix = Instruction {
        program_id: VERIFIER_ID,
        accounts: vec![],
        data,
    };

    msg!("Verifying solvency proof...");
    // If verification fails, the verifier returns an error and `invoke`
    // propagates it, aborting this instruction. Reaching the next line means
    // the proof is valid.
    invoke(&verify_ix, &[ctx.accounts.verifier.to_account_info()])?;

    // Record the attestation.
    let solvency = &mut ctx.accounts.solvency;
    solvency.commitment = commitment;
    solvency.threshold = threshold;
    solvency.verified = true;
    solvency.slot = Clock::get()?.slot;

    Ok(())
}

/// Encode a u32 as a 32-byte big-endian field element (BN254), matching the
/// circuit's `threshold: Field`: right-aligned, zero-padded.
fn u32_to_be_field(x: u32) -> [u8; 32] {
    let mut out = [0u8; 32];
    out[28..].copy_from_slice(&x.to_be_bytes());
    out
}
