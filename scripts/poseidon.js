#!/usr/bin/env node
//
// Poseidon helper for scripts/prove.sh.
//
// Computes the two hashes the delivery circuit constrains, using the same
// circomlib parameters the circuit compiles against:
//
//   commitment = Poseidon(secret)
//   nullifier  = Poseidon(secret, escrowId)
//
// Usage: node scripts/poseidon.js <secret> <escrowId>
// Output: a JSON object with decimal-string commitment and nullifier.

const {buildPoseidon} = require("circomlibjs");

async function main() {
    const [secret, escrowId] = process.argv.slice(2);

    if (secret === undefined || escrowId === undefined) {
        process.stderr.write("usage: node scripts/poseidon.js <secret> <escrowId>\n");
        process.exit(1);
    }

    const poseidon = await buildPoseidon();
    const F = poseidon.F;

    const s = BigInt(secret);
    const id = BigInt(escrowId);

    const commitment = F.toObject(poseidon([s]));
    const nullifier = F.toObject(poseidon([s, id]));

    // Emit both encodings: decimal for circom's input.json and for humans,
    // 0x-padded hex for the Solidity fixtures (forge's JSON reader coerces
    // long decimal strings and loses them, but reads hex cleanly).
    const hex = (n) => "0x" + n.toString(16).padStart(64, "0");

    process.stdout.write(
        JSON.stringify(
            {
                commitment: commitment.toString(),
                nullifier: nullifier.toString(),
                commitmentHex: hex(commitment),
                nullifierHex: hex(nullifier),
            },
            null,
            2,
        ) + "\n",
    );
}

main().catch((err) => {
    process.stderr.write(`poseidon: ${err.message}\n`);
    process.exit(1);
});
