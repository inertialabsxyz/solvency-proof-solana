pub mod constants;
pub mod error;
pub mod instructions;
pub mod state;

use anchor_lang::prelude::*;

pub use constants::*;
pub use instructions::*;
pub use state::*;

declare_id!("BWg55qMGUf4RUUiFqGAJKPuwLmLpDQRA4y3US97thnSw");

#[program]
pub mod solvency_proof {
    use super::*;

    pub fn attest_solvency(
        ctx: Context<AttestSolvency>,
        proof: Vec<u8>,
        threshold: u32,
        commitment: [u8; 32],
    ) -> Result<()> {
        solvency::handler(ctx, proof, threshold, commitment)
    }
}
