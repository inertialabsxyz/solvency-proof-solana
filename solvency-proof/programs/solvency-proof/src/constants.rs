use anchor_lang::prelude::*;

#[constant]
pub const SOLVENCY: &str = "solvency";
// Verifier program address — must match circuit/target/circuit-keypair.json,
// since that is the keypair the verifier .so is deployed with.
#[constant]
pub const VERIFIER_ID: Pubkey =
    anchor_lang::prelude::Pubkey::from_str_const("DFdj85YRHcvpdPsNMYBwvSuAyQ3kxKv9nUkShU8832wE");
