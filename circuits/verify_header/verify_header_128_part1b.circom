pragma circom 2.0.3;

include "./header_verification_128_split.circom";

// Part 1B: AccumulatedECCAdd (all 128 pubkeys)
// 128-validator version (~750K constraints, ~2GB RAM)
// Inputs: pubkeys[128], pubkeybits[128]
// Outputs: aggregated_pubkey[2][k]
component main = VerifyHeader128Part1B(128, 55, 7);
