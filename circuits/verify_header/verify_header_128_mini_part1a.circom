pragma circom 2.0.3;

include "./header_verification_128_split.circom";

// Part 1A MINI: HashToField + bitSum + PubkeyPoseidon
// 8-validator version for testing (~1K constraints, <1GB RAM)
// Inputs: pubkeys[8], pubkeybits[8], signing_root[32]
// Outputs: hash_field[2][2][k], bitSum, syncCommitteePoseidon
component main { public [ signing_root ] } = VerifyHeader128Part1A(8, 55, 7);
