pragma circom 2.0.3;

include "./header_verification_128_split.circom";

// Part 1D MINI: ClearCofactorG2 - First Half
// Same constraints as production (no validator dependency)
// (~10-15M constraints, ~20GB RAM)
// Inputs: R[2][2][k], R_isInfinity
// Outputs: xP_out, xP_isInfinity, psiP_out, neg_psiPy, add1_out, add1_isInfinity
component main = VerifyHeader128Part1D(55, 7);
