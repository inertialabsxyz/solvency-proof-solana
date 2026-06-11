use anchor_lang::prelude::*;

#[derive(Accounts)]
pub struct AttestSolvency {}

pub fn handler(ctx: Context<AttestSolvency>) -> Result<()> {
    msg!("Greetings from: {:?}", ctx.program_id);
    Ok(())
}
