struct SolvencyAttestation {
    commitment: [u8; 32],
    threshold: u32, // the bar it cleared
    verified: bool,
    slot: u64,
}
