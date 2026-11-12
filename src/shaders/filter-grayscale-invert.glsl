// filter-grayscale-invert - Rec. 709 luma, then inverted (light text on dark, no colour).
vec3 apply_filter(vec3 colour) {
    // Invert after the luma so white pages become black and vice versa.
    return vec3(1.0 - dot(colour, LUMA_WEIGHTS));
}
