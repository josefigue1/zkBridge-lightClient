pragma circom 2.0.3;

include "./header_verification_128_split.circom";

// Part 3B MINI: FinalExpHardPart + Verification
// Same constraints as production (no validator dependency)
// (~3.5M constraints, ~7GB RAM)
// Inputs: easy_out[6][2][k]
// Outputs: none (constrains result == 1)
component main = VerifyHeader128Part3B(55, 7);
