// filter-high-contrast - a strong per-channel S-curve that separates light and dark.
vec3 apply_filter(vec3 colour) {
    // Values below 0.25 go to black, above 0.75 to white, with a smooth ramp between.
    return smoothstep(vec3(0.25), vec3(0.75), colour);
}
