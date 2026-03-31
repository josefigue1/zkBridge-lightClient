pragma circom 2.0.3;

include "./header_verification_128_split.circom";

// Part 1B MINI: AccumulatedECCAdd (all 8 pubkeys)
// 8-validator version for testing (~40K constraints, <1GB RAM)
// Inputs: pubkeys[8], pubkeybits[8]
// Outputs: aggregated_pubkey[2][k]
component main = VerifyHeader128Part1B(8, 55, 7);
