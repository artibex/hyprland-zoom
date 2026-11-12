// filter-deuteranopia - correction for missing M cones (green-blind).
@INCLUDE cvd-common@

vec3 apply_filter(vec3 colour) {
    // Simulation (reference): M = 0.494207 L + 1.24827 S; L and S unchanged.
    // Error shift (reference): red error is moved into green and blue.
    return daltonize(colour,
        vec3(1.0, 0.0, 0.0), vec3(0.494207, 0.0, 1.24827), vec3(0.0, 0.0, 1.0),
        vec3(0.0, 0.0, 0.0), vec3(0.7, 1.0, 0.0), vec3(0.7, 0.0, 1.0));
}
