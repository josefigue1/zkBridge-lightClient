pragma circom 2.0.3;

include "../utils/pubkey_poseidon.circom";
include "./aggregate_bls_verify.circom";
include "../utils/circom-pairing/circuits/bls12_381_hash_to_G2.circom";
include "../utils/circom-pairing/circuits/final_exp.circom";
include "../utils/circom-pairing/circuits/pairing.circom";

// =============================================================================
// 128-Validator Split Header Verification Templates
// =============================================================================
// These templates divide VerifyHeader into 8 parts to reduce RAM usage to ~25GB per part:
//   Part1A: HashToField + bitSum + PubkeyPoseidon
//   Part1B: AccumulatedECCAdd (all 128 pubkeys)
//   Part1C: Checks + MapToG2 (before cofactor clearing)
//   Part1D: ClearCofactorG2 - First Half
//   Part1E: ClearCofactorG2 - Second Half
//   Part2:  MillerLoop
//   Part3A: FinalExpEasyPart
//   Part3B: FinalExpHardPart + Verification
// =============================================================================


// -----------------------------------------------------------------------------
// Part 1A: HashToField + bitSum + PubkeyPoseidon
// -----------------------------------------------------------------------------
// Inputs: signing_root, pubkeys, pubkeybits
// Outputs: hash_field, bitSum, syncCommitteePoseidon
// Constraints: ~30K for b=128
// -----------------------------------------------------------------------------
template VerifyHeader128Part1A(b, n, k) {
    signal input pubkeys[b][2][k];
    signal input pubkeybits[b];
    signal input signing_root[32];

    // Outputs
    signal output hash_field[2][2][k];
    signal output bitSum;
    signal output syncCommitteePoseidon;

    // Step 1: HashToField - Convert signing_root to field elements (Fp2)
    component hashToField = HashToField(32, 2);
    for (var i = 0; i < 32; i++) {
        hashToField.msg[i] <== signing_root[i];
    }

    for (var i = 0; i < 2; i++) {
        for (var j = 0; j < 2; j++) {
            for (var l = 0; l < k; l++) {
                hash_field[i][j][l] <== hashToField.result[i][j][l];
            }
        }
    }

    // Step 2: Calculate bitSum
    signal partialSum[b-1];
    for (var i = 0; i < b - 1; i++) {
        if (i == 0) {
            partialSum[i] <== pubkeybits[0] + pubkeybits[1];
        } else {
            partialSum[i] <== partialSum[i-1] + pubkeybits[i+1];
        }
    }
    bitSum <== partialSum[b-2];

    // Step 3: Calculate Poseidon merkle root of pubkeys
    component poseidonSyncCommittee = PubkeyPoseidon(b, k);
    for (var i = 0; i < b; i++) {
        for (var j = 0; j < k; j++) {
            poseidonSyncCommittee.pubkeys[i][0][j] <== pubkeys[i][0][j];
            poseidonSyncCommittee.pubkeys[i][1][j] <== pubkeys[i][1][j];
        }
    }
    syncCommitteePoseidon <== poseidonSyncCommittee.out;
}


// -----------------------------------------------------------------------------
// Part 1B: AccumulatedECCAdd (all b pubkeys)
// -----------------------------------------------------------------------------
// Inputs: pubkeys, pubkeybits
// Outputs: aggregated_pubkey
// Constraints: ~750K for b=128 (127 additions × ~6K each)
// -----------------------------------------------------------------------------
template VerifyHeader128Part1B(b, n, k) {
    signal input pubkeys[b][2][k];
    signal input pubkeybits[b];

    signal output aggregated_pubkey[2][k];

    component aggregateKey = AccumulatedECCAdd(b, n, k);
    for (var i = 0; i < b; i++) {
        aggregateKey.pubkeybits[i] <== pubkeybits[i];
        for (var j = 0; j < k; j++) {
            aggregateKey.pubkeys[i][0][j] <== pubkeys[i][0][j];
            aggregateKey.pubkeys[i][1][j] <== pubkeys[i][1][j];
        }
    }

    for (var i = 0; i < 2; i++) {
        for (var j = 0; j < k; j++) {
            aggregated_pubkey[i][j] <== aggregateKey.out[i][j];
        }
    }
}


// -----------------------------------------------------------------------------
// Part 1C: Checks + MapToG2 (before cofactor clearing)
// -----------------------------------------------------------------------------
// Inputs: aggregated_pubkey, signature, hash_field
// Outputs: R (point before cofactor), R_isInfinity
// Constraints: ~5-10M
// -----------------------------------------------------------------------------
template VerifyHeader128Part1C(n, k) {
    signal input aggregated_pubkey[2][k];
    signal input signature[2][2][k];
    signal input hash_field[2][2][k];

    signal output R[2][2][k];
    signal output R_isInfinity;

    var p[50] = get_BLS12_381_prime(n, k);

    // Range checks (all values < p)
    component lt[10];
    for (var i = 0; i < 10; i++) {
        lt[i] = BigLessThan(n, k);
        for (var idx = 0; idx < k; idx++)
            lt[i].b[idx] <== p[idx];
    }
    for (var idx = 0; idx < k; idx++) {
        lt[0].a[idx] <== aggregated_pubkey[0][idx];
        lt[1].a[idx] <== aggregated_pubkey[1][idx];
        lt[2].a[idx] <== signature[0][0][idx];
        lt[3].a[idx] <== signature[0][1][idx];
        lt[4].a[idx] <== signature[1][0][idx];
        lt[5].a[idx] <== signature[1][1][idx];
        lt[6].a[idx] <== hash_field[0][0][idx];
        lt[7].a[idx] <== hash_field[0][1][idx];
        lt[8].a[idx] <== hash_field[1][0][idx];
        lt[9].a[idx] <== hash_field[1][1][idx];
    }
    var r = 0;
    for (var i = 0; i < 10; i++) {
        r += lt[i].out;
    }
    r === 10;

    // Range checks for registers
    component check[5];
    for (var i = 0; i < 5; i++)
        check[i] = RangeCheck2D(n, k);
    for (var i = 0; i < 2; i++) {
        for (var idx = 0; idx < k; idx++) {
            check[0].in[i][idx] <== aggregated_pubkey[i][idx];
            check[1].in[i][idx] <== signature[0][i][idx];
            check[2].in[i][idx] <== signature[1][i][idx];
            check[3].in[i][idx] <== hash_field[0][i][idx];
            check[4].in[i][idx] <== hash_field[1][i][idx];
        }
    }

    // Subgroup check for aggregated pubkey (G1)
    component pubkey_valid = SubgroupCheckG1(n, k);
    for (var i = 0; i < 2; i++) {
        for (var idx = 0; idx < k; idx++)
            pubkey_valid.in[i][idx] <== aggregated_pubkey[i][idx];
    }

    // Subgroup check for signature (G2)
    component signature_valid = SubgroupCheckG2(n, k);
    for (var i = 0; i < 2; i++) {
        for (var j = 0; j < 2; j++) {
            for (var idx = 0; idx < k; idx++)
                signature_valid.in[i][j][idx] <== signature[i][j][idx];
        }
    }

    // MapToG2 without cofactor clearing (OptSimpleSWU2 + Iso3Map only)
    // Two SWU maps
    component Qp[2];
    for (var i = 0; i < 2; i++) {
        Qp[i] = OptSimpleSWU2(n, k);
        for (var j = 0; j < 2; j++) {
            for (var idx = 0; idx < k; idx++)
                Qp[i].in[j][idx] <== hash_field[i][j][idx];
        }
    }

    // Add the two points on E2'
    component Rp = EllipticCurveAddFp2(n, k, [0, 240], [1012, 1012], p);
    for (var i = 0; i < 2; i++) {
        for (var j = 0; j < 2; j++) {
            for (var idx = 0; idx < k; idx++) {
                Rp.a[i][j][idx] <== Qp[0].out[i][j][idx];
                Rp.b[i][j][idx] <== Qp[1].out[i][j][idx];
            }
        }
    }
    Rp.aIsInfinity <== 0;
    Rp.bIsInfinity <== 0;

    // Apply 3-isogeny
    component Riso = Iso3Map(n, k);
    for (var i = 0; i < 2; i++) {
        for (var j = 0; j < 2; j++) {
            for (var idx = 0; idx < k; idx++)
                Riso.in[i][j][idx] <== Rp.out[i][j][idx];
        }
    }

    // Output R (before cofactor clearing)
    for (var i = 0; i < 2; i++) {
        for (var j = 0; j < 2; j++) {
            for (var idx = 0; idx < k; idx++)
                R[i][j][idx] <== Riso.out[i][j][idx];
        }
    }
    R_isInfinity <== Riso.isInfinity + Rp.isInfinity - Riso.isInfinity * Rp.isInfinity;
}


// -----------------------------------------------------------------------------
// Part 1D: ClearCofactorG2 - First Half
// -----------------------------------------------------------------------------
// Computes: xP, psiP, -P, -psiP, 2P, add[0], add[1], and first scalar mult
// Inputs: R, R_isInfinity
// Outputs: intermediate values for Part1E
// Constraints: ~10-15M
// -----------------------------------------------------------------------------
template VerifyHeader128Part1D(n, k) {
    signal input R[2][2][k];
    signal input R_isInfinity;

    // Outputs: intermediate state for Part1E
    signal output xP_out[2][2][k];
    signal output xP_isInfinity;
    signal output psiP_out[2][2][k];
    signal output neg_psiPy[2][k];
    signal output add1_out[2][2][k];
    signal output add1_isInfinity;

    var p[50] = get_BLS12_381_prime(n, k);
    var x_abs = get_BLS12_381_parameter();
    var a[2] = [0, 0];
    var b[2] = [4, 4];
    var dummy_point[2][2][50] = get_generator_G2(n, k);

    // Replace R with dummy_point if R_isInfinity = 1
    signal P[2][2][k];
    for (var i = 0; i < 2; i++) {
        for (var j = 0; j < 2; j++) {
            for (var idx = 0; idx < k; idx++) {
                P[i][j][idx] <== R[i][j][idx] + R_isInfinity * (dummy_point[i][j][idx] - R[i][j][idx]);
            }
        }
    }

    // xP = [x_abs] * P
    component xP = EllipticCurveScalarMultiplyFp2(n, k, b, x_abs, p);
    xP.inIsInfinity <== R_isInfinity;
    for (var i = 0; i < 2; i++) {
        for (var j = 0; j < 2; j++) {
            for (var idx = 0; idx < k; idx++)
                xP.in[i][j][idx] <== P[i][j][idx];
        }
    }

    // psiP = psi(P)
    component psiP = EndomorphismPsi(n, k, p);
    for (var i = 0; i < 2; i++) {
        for (var j = 0; j < 2; j++) {
            for (var idx = 0; idx < k; idx++)
                psiP.in[i][j][idx] <== P[i][j][idx];
        }
    }

    // -psiP_y
    component neg_psiPy_comp = Fp2Negate(n, k, p);
    for (var j = 0; j < 2; j++) {
        for (var idx = 0; idx < k; idx++)
            neg_psiPy_comp.in[j][idx] <== psiP.out[1][j][idx];
    }

    // add[0] = xP + P
    component add0 = EllipticCurveAddFp2(n, k, a, b, p);
    for (var i = 0; i < 2; i++) {
        for (var j = 0; j < 2; j++) {
            for (var idx = 0; idx < k; idx++) {
                add0.a[i][j][idx] <== xP.out[i][j][idx];
                add0.b[i][j][idx] <== P[i][j][idx];
            }
        }
    }
    add0.aIsInfinity <== xP.isInfinity;
    add0.bIsInfinity <== R_isInfinity;

    // add[1] = add[0] - psiP = add[0] + (-psiP)
    component add1 = EllipticCurveAddFp2(n, k, a, b, p);
    for (var i = 0; i < 2; i++) {
        for (var j = 0; j < 2; j++) {
            for (var idx = 0; idx < k; idx++) {
                add1.a[i][j][idx] <== add0.out[i][j][idx];
                if (i == 0)
                    add1.b[i][j][idx] <== psiP.out[i][j][idx];
                else
                    add1.b[i][j][idx] <== neg_psiPy_comp.out[j][idx];
            }
        }
    }
    add1.aIsInfinity <== add0.isInfinity;
    add1.bIsInfinity <== R_isInfinity;

    // Output intermediate values
    for (var i = 0; i < 2; i++) {
        for (var j = 0; j < 2; j++) {
            for (var idx = 0; idx < k; idx++) {
                xP_out[i][j][idx] <== xP.out[i][j][idx];
                psiP_out[i][j][idx] <== psiP.out[i][j][idx];
                add1_out[i][j][idx] <== add1.out[i][j][idx];
            }
        }
    }
    for (var j = 0; j < 2; j++) {
        for (var idx = 0; idx < k; idx++)
            neg_psiPy[j][idx] <== neg_psiPy_comp.out[j][idx];
    }
    xP_isInfinity <== xP.isInfinity;
    add1_isInfinity <== add1.isInfinity;
}


// -----------------------------------------------------------------------------
// Part 1E: ClearCofactorG2 - Second Half
// -----------------------------------------------------------------------------
// Completes: second scalar mult and final additions
// Inputs: intermediate values from Part1D, P (original point), R_isInfinity
// Outputs: Hm_G2
// Constraints: ~10-15M
// -----------------------------------------------------------------------------
template VerifyHeader128Part1E(n, k) {
    signal input R[2][2][k];
    signal input R_isInfinity;
    signal input psiP[2][2][k];
    signal input neg_psiPy[2][k];
    signal input add1[2][2][k];
    signal input add1_isInfinity;

    signal output Hm_G2[2][2][k];
    signal output Hm_isInfinity;

    var p[50] = get_BLS12_381_prime(n, k);
    var x_abs = get_BLS12_381_parameter();
    var a[2] = [0, 0];
    var b[2] = [4, 4];
    var dummy_point[2][2][50] = get_generator_G2(n, k);

    // Reconstruct P from R
    signal P[2][2][k];
    for (var i = 0; i < 2; i++) {
        for (var j = 0; j < 2; j++) {
            for (var idx = 0; idx < k; idx++) {
                P[i][j][idx] <== R[i][j][idx] + R_isInfinity * (dummy_point[i][j][idx] - R[i][j][idx]);
            }
        }
    }

    // -P_y
    component neg_Py = Fp2Negate(n, k, p);
    for (var j = 0; j < 2; j++) {
        for (var idx = 0; idx < k; idx++)
            neg_Py.in[j][idx] <== P[1][j][idx];
    }

    // 2P for psi2
    component doubP = EllipticCurveDoubleFp2(n, k, a, b, p);
    for (var i = 0; i < 2; i++) {
        for (var j = 0; j < 2; j++) {
            for (var idx = 0; idx < k; idx++)
                doubP.in[i][j][idx] <== P[i][j][idx];
        }
    }

    // psi2(2P)
    component psi22P = EndomorphismPsi2(n, k, p);
    for (var i = 0; i < 2; i++) {
        for (var j = 0; j < 2; j++) {
            for (var idx = 0; idx < k; idx++)
                psi22P.in[i][j][idx] <== doubP.out[i][j][idx];
        }
    }

    // xadd1 = [x_abs] * add1
    component xadd1 = EllipticCurveScalarMultiplyFp2(n, k, b, x_abs, p);
    for (var i = 0; i < 2; i++) {
        for (var j = 0; j < 2; j++) {
            for (var idx = 0; idx < k; idx++)
                xadd1.in[i][j][idx] <== add1[i][j][idx];
        }
    }
    xadd1.inIsInfinity <== add1_isInfinity;

    // add[2] = xadd1 - P
    component add2 = EllipticCurveAddFp2(n, k, a, b, p);
    for (var i = 0; i < 2; i++) {
        for (var j = 0; j < 2; j++) {
            for (var idx = 0; idx < k; idx++) {
                add2.a[i][j][idx] <== xadd1.out[i][j][idx];
                if (i == 0)
                    add2.b[i][j][idx] <== P[i][j][idx];
                else
                    add2.b[i][j][idx] <== neg_Py.out[j][idx];
            }
        }
    }
    add2.aIsInfinity <== xadd1.isInfinity;
    add2.bIsInfinity <== R_isInfinity;

    // add[3] = add2 - psiP
    component add3 = EllipticCurveAddFp2(n, k, a, b, p);
    for (var i = 0; i < 2; i++) {
        for (var j = 0; j < 2; j++) {
            for (var idx = 0; idx < k; idx++) {
                add3.a[i][j][idx] <== add2.out[i][j][idx];
                if (i == 0)
                    add3.b[i][j][idx] <== psiP[i][j][idx];
                else
                    add3.b[i][j][idx] <== neg_psiPy[j][idx];
            }
        }
    }
    add3.aIsInfinity <== add2.isInfinity;
    add3.bIsInfinity <== R_isInfinity;

    // add[4] = add3 + psi22P
    component add4 = EllipticCurveAddFp2(n, k, a, b, p);
    for (var i = 0; i < 2; i++) {
        for (var j = 0; j < 2; j++) {
            for (var idx = 0; idx < k; idx++) {
                add4.a[i][j][idx] <== add3.out[i][j][idx];
                add4.b[i][j][idx] <== psi22P.out[i][j][idx];
            }
        }
    }
    add4.aIsInfinity <== add3.isInfinity;
    add4.bIsInfinity <== R_isInfinity;

    // Output
    Hm_isInfinity <== add4.isInfinity + R_isInfinity - add4.isInfinity * R_isInfinity;
    for (var i = 0; i < 2; i++) {
        for (var j = 0; j < 2; j++) {
            for (var idx = 0; idx < k; idx++)
                Hm_G2[i][j][idx] <== add4.out[i][j][idx] + Hm_isInfinity * (dummy_point[i][j][idx] - add4.out[i][j][idx]);
        }
    }
}


// -----------------------------------------------------------------------------
// Part 2: MillerLoop
// -----------------------------------------------------------------------------
// Same as before - computes the Miller loop for BLS pairing
// Inputs: aggregated_pubkey, signature, Hm_G2
// Outputs: miller_out
// Constraints: ~8M
// -----------------------------------------------------------------------------
template VerifyHeader128Part2(n, k) {
    signal input aggregated_pubkey[2][k];
    signal input signature[2][2][k];
    signal input Hm_G2[2][2][k];

    signal output miller_out[6][2][k];

    var q[50] = get_BLS12_381_prime(n, k);
    var x = get_BLS12_381_parameter();
    var g1[2][50] = get_generator_G1(n, k);

    // Negate signature
    signal neg_s[2][2][k];
    component neg[2];
    for (var j = 0; j < 2; j++) {
        neg[j] = FpNegate(n, k, q);
        for (var idx = 0; idx < k; idx++)
            neg[j].in[idx] <== signature[1][j][idx];
        for (var idx = 0; idx < k; idx++) {
            neg_s[0][j][idx] <== signature[0][j][idx];
            neg_s[1][j][idx] <== neg[j].out[idx];
        }
    }

    // Miller loop
    component miller = MillerLoopFp2Two(n, k, [4,4], x, q);
    for (var i = 0; i < 2; i++) {
        for (var j = 0; j < 2; j++) {
            for (var idx = 0; idx < k; idx++) {
                miller.P[0][i][j][idx] <== neg_s[i][j][idx];
                miller.P[1][i][j][idx] <== Hm_G2[i][j][idx];
            }
        }
    }
    for (var i = 0; i < 2; i++) {
        for (var idx = 0; idx < k; idx++) {
            miller.Q[0][i][idx] <== g1[i][idx];
            miller.Q[1][i][idx] <== aggregated_pubkey[i][idx];
        }
    }

    for (var i = 0; i < 6; i++) {
        for (var j = 0; j < 2; j++) {
            for (var idx = 0; idx < k; idx++)
                miller_out[i][j][idx] <== miller.out[i][j][idx];
        }
    }
}


// -----------------------------------------------------------------------------
// Part 3A: FinalExpEasyPart
// -----------------------------------------------------------------------------
// Computes: in^{(q^6 - 1)(q^2 + 1)}
// Inputs: miller_out
// Outputs: easy_out
// Constraints: ~1.5M
// -----------------------------------------------------------------------------
template VerifyHeader128Part3A(n, k) {
    signal input miller_out[6][2][k];
    signal output easy_out[6][2][k];

    var p[50] = get_BLS12_381_prime(n, k);

    component easyPart = FinalExpEasyPart(n, k, p);
    for (var id = 0; id < 6; id++) {
        for (var eps = 0; eps < 2; eps++) {
            for (var j = 0; j < k; j++)
                easyPart.in[id][eps][j] <== miller_out[id][eps][j];
        }
    }

    for (var id = 0; id < 6; id++) {
        for (var eps = 0; eps < 2; eps++) {
            for (var j = 0; j < k; j++)
                easy_out[id][eps][j] <== easyPart.out[id][eps][j];
        }
    }
}


// -----------------------------------------------------------------------------
// Part 3B: FinalExpHardPart + Verification
// -----------------------------------------------------------------------------
// Completes final exponentiation and verifies result == 1
// Inputs: easy_out
// Outputs: (none - constrains result)
// Constraints: ~3.5M
// -----------------------------------------------------------------------------
template VerifyHeader128Part3B(n, k) {
    signal input easy_out[6][2][k];

    var p[50] = get_BLS12_381_prime(n, k);

    component hardPart = FinalExpHardPart(n, k, p);
    for (var id = 0; id < 6; id++) {
        for (var eps = 0; eps < 2; eps++) {
            for (var j = 0; j < k; j++)
                hardPart.in[id][eps][j] <== easy_out[id][eps][j];
        }
    }

    // Verify result == 1
    // In Fp12, 1 = (1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    // So out[0][0][0] should be 1, everything else 0
    component is_valid[6][2][k];
    var total = 12 * k;
    for (var i = 0; i < 6; i++) {
        for (var j = 0; j < 2; j++) {
            for (var idx = 0; idx < k; idx++) {
                is_valid[i][j][idx] = IsZero();
                if (i == 0 && j == 0 && idx == 0)
                    is_valid[i][j][idx].in <== hardPart.out[i][j][idx] - 1;
                else
                    is_valid[i][j][idx].in <== hardPart.out[i][j][idx];
                total -= is_valid[i][j][idx].out;
            }
        }
    }
    component valid = IsZero();
    valid.in <== total;
    valid.out === 1;
}
