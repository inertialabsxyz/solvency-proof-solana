use anchor_lang::prelude::*;

#[derive(InitSpace)]
#[account]
pub struct SolvencyAttestation {
    pub commitment: [u8; 32],
    pub threshold: u32, // the bar it cleared
    pub verified: bool,
    pub slot: u64,
}
