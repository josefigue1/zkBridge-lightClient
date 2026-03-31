pragma circom 2.0.3;

include "./header_verification_128_split.circom";

// Part 3A MINI: FinalExpEasyPart
// Same constraints as production (no validator dependency)
// (~1.5M constraints, ~3GB RAM)
// Inputs: miller_out[6][2][k]
// Outputs: easy_out[6][2][k]
component main = VerifyHeader128Part3A(55, 7);
