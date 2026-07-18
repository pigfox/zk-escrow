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

    process.stdout.write(
        JSON.stringify(
            {
                commitment: commitment.toString(),
                nullifier: nullifier.toString(),
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
