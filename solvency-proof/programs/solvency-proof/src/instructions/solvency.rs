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
    let mut public_inputs = Vec::with_capacity(64);
    public_inputs.extend_from_slice(&u32_to_be_field(threshold)); // threshold
    public_inputs.extend_from_slice(&commitment); // commitment

    let mut data = Vec::with_capacity(proof.len() + public_inputs.len());
    data.extend_from_slice(&proof);
    data.extend_from_slice(&public_inputs);

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
