// filter-protanopia - correction for missing L cones (red-blind).
@INCLUDE cvd-common@

vec3 apply_filter(vec3 colour) {
    // Simulation (reference): L = 2.02344 M - 2.52581 S; M and S unchanged.
    // Error shift (reference): red error is moved into green and blue.
    return daltonize(colour,
        vec3(0.0, 2.02344, -2.52581), vec3(0.0, 1.0, 0.0), vec3(0.0, 0.0, 1.0),
        vec3(0.0, 0.0, 0.0), vec3(0.7, 1.0, 0.0), vec3(0.7, 0.0, 1.0));
}
