// filter-tritanopia - correction for missing S cones (blue-yellow blind).
@INCLUDE cvd-common@

vec3 apply_filter(vec3 colour) {
    // Simulation: Machado et al. 2009, tritanopia, severity 1.0 (linear RGB).
    // Error shift: our own choice (Fidaner et al. define the shift for red/green deficiencies
    // only): the lost blue information is redistributed into red and green, the channels
    // that tritanopes still discriminate; blue itself is left unchanged.
    return daltonize(colour,
        vec3(1.255528, -0.076749, -0.178779), vec3(-0.078411, 0.930809, 0.147602),
        vec3(0.004733, 0.691367, 0.303900),
        vec3(1.0, 0.0, 0.7), vec3(0.0, 1.0, 0.7), vec3(0.0, 0.0, 0.0));
}
