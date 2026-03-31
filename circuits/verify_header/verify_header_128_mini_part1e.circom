pragma circom 2.0.3;

include "./header_verification_128_split.circom";

// Part 1E MINI: ClearCofactorG2 - Second Half
// Same constraints as production (no validator dependency)
// (~10-15M constraints, ~20GB RAM)
// Inputs: R, R_isInfinity, psiP, neg_psiPy, add1, add1_isInfinity
// Outputs: Hm_G2[2][2][k], Hm_isInfinity
component main = VerifyHeader128Part1E(55, 7);
