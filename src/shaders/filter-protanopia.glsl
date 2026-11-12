// filter-protanopia - correction for missing L cones (red-blind).
@INCLUDE cvd-common@

vec3 apply_filter(vec3 colour) {
    // Simulation: Machado et al. 2009, protanopia, severity 1.0 (linear RGB).
    // Error shift: Fidaner et al. 2005 - red error is moved into green and blue.
    return daltonize(colour,
        vec3(0.152286, 1.052583, -0.204868), vec3(0.114503, 0.786281, 0.099216),
        vec3(-0.003882, -0.048116, 1.051998),
        vec3(0.0, 0.0, 0.0), vec3(0.7, 1.0, 0.0), vec3(0.7, 0.0, 1.0));
}
