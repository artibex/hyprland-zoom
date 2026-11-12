// cvd-common - Daltonize-style colour-blindness correction shared by the three CVD filters.
//
// Simulation: the severity-1.0 (full dichromacy) matrices of Machado, Oliveira, Fernandes,
// "A Physiologically-based Model for Simulation of Color Vision Deficiency",
// IEEE Transactions on Visualization and Computer Graphics 15(6), 2009. They act on LINEAR RGB.
// Correction: the "Daltonize" idea of Fidaner, Lin, Ozguven, "Analysis of Color Blindness",
// Stanford 2005: take the error (what the viewer cannot see) and shift it into channels the
// viewer can still tell apart, then add it to the original colour.
// Screen shaders see gamma-encoded values, so the maths runs on an approximate 2.2 gamma.

// Approximate display gamma used to linearise the frame.
const float DISPLAY_GAMMA = 2.2;

// daltonize - simulate a colour-vision deficiency and shift the lost information.
// The simulation rows give the simulated colour as dot products with the linear input;
// the shift rows redistribute the error (original minus simulated) per output channel.
vec3 daltonize(vec3 colour, vec3 sim_r, vec3 sim_g, vec3 sim_b,
               vec3 shift_r, vec3 shift_g, vec3 shift_b) {
    // Work in linear light: the simulation matrices are defined there.
    vec3 linear = pow(colour, vec3(DISPLAY_GAMMA));
    vec3 simulated = vec3(dot(sim_r, linear), dot(sim_g, linear), dot(sim_b, linear));
    // What the viewer loses, moved into channels they can still use.
    vec3 lost = linear - simulated;
    vec3 shifted = vec3(dot(shift_r, lost), dot(shift_g, lost), dot(shift_b, lost));
    // Add the shifted error to the original and go back to the gamma-encoded range.
    vec3 corrected = clamp(linear + shifted, 0.0, 1.0);
    return pow(corrected, vec3(1.0 / DISPLAY_GAMMA));
}
