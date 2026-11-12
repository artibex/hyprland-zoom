// cvd-common - Daltonize-style colour-blindness correction shared by the three CVD filters.
//
// Method: Fidaner, Lin, Ozguven, "Analysis of Color Blindness" (Stanford, 2005) as implemented
// in the widely used daltonize.org reference code. Steps: RGB -> LMS cone space, simulate the
// missing cone, convert back, take the error (what the viewer cannot see) and shift that error
// into channels the viewer can still tell apart, then add it to the original colour.
// The LMS matrices below are the constants of that reference implementation.

// rgb_to_lms - convert RGB to cone responses (reference matrix, one row per cone).
vec3 rgb_to_lms(vec3 colour) {
    return vec3(
        dot(vec3(17.8824, 43.5161, 4.11935), colour),
        dot(vec3(3.45565, 27.1554, 3.86714), colour),
        dot(vec3(0.0299566, 0.184309, 1.46709), colour));
}

// lms_to_rgb - inverse of rgb_to_lms (reference matrix).
vec3 lms_to_rgb(vec3 cones) {
    return vec3(
        dot(vec3(0.0809444479, -0.130504409, 0.116721066), cones),
        dot(vec3(-0.0102485335, 0.0540193266, -0.113614708), cones),
        dot(vec3(-0.000365296938, -0.00412161469, 0.693511405), cones));
}

// daltonize - simulate a cone deficiency and shift the lost information to visible channels.
// The simulation rows pick each simulated cone response; the shift rows redistribute the error.
vec3 daltonize(vec3 colour, vec3 sim_l, vec3 sim_m, vec3 sim_s,
               vec3 shift_r, vec3 shift_g, vec3 shift_b) {
    // What a person with the deficiency would see.
    vec3 cones = rgb_to_lms(colour);
    vec3 simulated = lms_to_rgb(vec3(dot(sim_l, cones), dot(sim_m, cones), dot(sim_s, cones)));
    // The difference is the information they lose; move it into channels they can use.
    vec3 lost = colour - simulated;
    vec3 shifted = vec3(dot(shift_r, lost), dot(shift_g, lost), dot(shift_b, lost));
    return clamp(colour + shifted, 0.0, 1.0);
}
