pragma circom 2.0.3;

include "./header_verification_128_split.circom";

// Part 1A: HashToField + bitSum + PubkeyPoseidon
// 128-validator version (~30K constraints, <1GB RAM)
// Inputs: pubkeys[128], pubkeybits[128], signing_root[32]
// Outputs: hash_field[2][2][k], bitSum, syncCommitteePoseidon
component main { public [ signing_root ] } = VerifyHeader128Part1A(128, 55, 7);
