pragma circom 2.1.9;

include "poseidon.circom";

/// Delivery
///
/// Proves knowledge of a delivery secret `secret` whose Poseidon hash equals
/// the `commitment` recorded on an escrow, without revealing `secret`.
///
/// Public signals, in circom's ordering (main-component outputs first, then the
/// signals listed as public):
///
///   [0] nullifier   — output, Poseidon(secret, escrowId)
///   [1] commitment  — input,  Poseidon(secret)
///   [2] escrowId    — input,  the escrow this proof may be spent against
///
/// Deriving the nullifier from BOTH the secret and the escrowId is what stops
/// replay: the same secret produces a different nullifier per escrow, and
/// EscrowUpgradeable stores spent nullifiers, so one proof settles exactly one
/// escrow exactly once. A proof generated for escrow 7 carries a nullifier that
/// only validates when the contract feeds escrowId 7 back in as a public input.
template Delivery() {
    // Private witness.
    signal input secret;

    // Public inputs.
    signal input commitment;
    signal input escrowId;

    // Public output.
    signal output nullifier;

    // commitment == Poseidon(secret)
    component commitmentHash = Poseidon(1);
    commitmentHash.inputs[0] <== secret;
    commitmentHash.out === commitment;

    // nullifier == Poseidon(secret, escrowId)
    component nullifierHash = Poseidon(2);
    nullifierHash.inputs[0] <== secret;
    nullifierHash.inputs[1] <== escrowId;
    nullifier <== nullifierHash.out;
}

component main {public [commitment, escrowId]} = Delivery();
