pragma circom 2.0.3;

include "./header_verification_128_split.circom";

// Part 1C: Checks + MapToG2 (before cofactor clearing)
// (~5-10M constraints, ~15GB RAM)
// Inputs: aggregated_pubkey[2][k], signature[2][2][k], hash_field[2][2][k]
// Outputs: R[2][2][k], R_isInfinity
component main = VerifyHeader128Part1C(55, 7);
