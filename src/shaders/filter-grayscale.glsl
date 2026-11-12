// filter-grayscale - Rec. 709 luma grayscale.
vec3 apply_filter(vec3 colour) {
    // One luma value replaces all three channels.
    return vec3(dot(colour, LUMA_WEIGHTS));
}
