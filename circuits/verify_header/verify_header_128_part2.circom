pragma circom 2.0.3;

include "./header_verification_128_split.circom";

// Part 2: MillerLoop
// (~8M constraints, ~16GB RAM)
// Inputs: aggregated_pubkey[2][k], signature[2][2][k], Hm_G2[2][2][k]
// Outputs: miller_out[6][2][k]
component main = VerifyHeader128Part2(55, 7);
