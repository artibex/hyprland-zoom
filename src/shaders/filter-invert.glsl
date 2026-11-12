// filter-invert - plain RGB inversion (every channel c becomes 1 - c).
vec3 apply_filter(vec3 colour) {
    // Straight inversion: white <-> black, but hues flip to their complements as well.
    return vec3(1.0) - colour;
}
