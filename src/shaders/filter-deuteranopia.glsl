// filter-deuteranopia - correction for missing M cones (green-blind).
@INCLUDE cvd-common@

vec3 apply_filter(vec3 colour) {
    // Simulation: Machado et al. 2009, deuteranopia, severity 1.0 (linear RGB).
    // Error shift: Fidaner et al. 2005 - red error is moved into green and blue.
    return daltonize(colour,
        vec3(0.367322, 0.860646, -0.227968), vec3(0.280085, 0.672501, 0.047413),
        vec3(-0.011820, 0.042940, 0.968881),
        vec3(0.0, 0.0, 0.0), vec3(0.7, 1.0, 0.0), vec3(0.7, 0.0, 1.0));
}
