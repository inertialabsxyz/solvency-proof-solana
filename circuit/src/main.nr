use poseidon::poseidon2::Poseidon2;

global N: u32 = 4;

fn main(balances: [Field; N], threshold: pub Field, commitment: pub Field) {
    assert(Poseidon2::hash(balances, N) == commitment, "commitment failed");

    let mut sum: u64 = 0;
    for i in 0..N {
        let b: u64 = balances[i] as u64;
        sum += b;
    }

    let threshold_u64: u64 = threshold as u64;
    assert(sum >= threshold_u64, "insolvent: sum below threshold");
}

#[test]
fn test_main() {
    let commitment = Poseidon2::hash([1, 2, 3, 4], N);
    main([1, 2, 3, 4], 4, commitment);
}

// Fails for any reason (here: threshold exceeds the balance sum).
#[test(should_fail)]
fn test_insolvent() {
    let commitment = Poseidon2::hash([1, 2, 3, 4], N);
    main([1, 2, 3, 4], 1000, commitment);
}

// Stricter: passes only if it fails with this specific message,
// so an unrelated failure (e.g. bad commitment) won't mask the bug.
#[test(should_fail_with = "insolvent")]
fn test_insolvent_with_message() {
    let commitment = Poseidon2::hash([1, 2, 3, 4], N);
    main([1, 2, 3, 4], 1000, commitment);
}

// A wrong commitment fails the hash assertion, not the threshold one.
#[test(should_fail_with = "commitment")]
fn test_bad_commitment() {
    main([1, 2, 3, 4], 4, 0);
}
