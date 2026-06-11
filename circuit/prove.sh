export PATH="$PWD/sunspot/go:$PATH"
export GNARK_VERIFIER_BIN="$PWD/sunspot/gnark-solana/crates/verifier-bin"
echo "Execute Nargo"
nargo execute
echo "Setup Sunspot"
sunspot compile target/circuit.json
sunspot setup target/circuit.ccs

echo "Creating proof with sunspot"
sunspot prove target/circuit.json target/circuit.gz target/circuit.ccs target/circuit.pk

echo "Generate Solana Verifier"
sunspot deploy target/circuit.vk
