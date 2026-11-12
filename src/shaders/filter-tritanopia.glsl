// filter-tritanopia - correction for missing S cones (blue-yellow blind).
@INCLUDE cvd-common@

vec3 apply_filter(vec3 colour) {
    // Simulation (reference): S = -0.395913 L + 0.801109 M; L and M unchanged.
    // Error shift: our own choice (the reference reuses the red/green shift for every type);
    // the lost blue information is redistributed into red and green, the channels that
    // tritanopes still discriminate.
    return daltonize(colour,
        vec3(1.0, 0.0, 0.0), vec3(0.0, 1.0, 0.0), vec3(-0.395913, 0.801109, 0.0),
        vec3(1.0, 0.0, 0.7), vec3(0.0, 1.0, 0.7), vec3(0.0, 0.0, 0.0));
}
