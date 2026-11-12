// filter-smart-invert - "dark mode" look that keeps text readable: mirror the relative luminance
// so that every WCAG contrast ratio is preserved, and keep the direction of the colour.
// White becomes black, dark text becomes light text, a blue link stays a clearly visible blue.
//
// Method: WCAG 2.x defines the contrast of two colours as (lighter + 0.05) / (darker + 0.05) on
// the relative luminance Y (https://www.w3.org/TR/WCAG21/#dfn-contrast-ratio). The map
//     Y' = 0.0525 / (Y + 0.05) - 0.05
// is an involution on [0, 1] (white <-> black) and keeps that ratio for EVERY pair of colours:
//     (Y1' + 0.05) / (Y2' + 0.05) = (Y2 + 0.05) / (Y1 + 0.05).
// The earlier HSL lightness flip left pure blue at contrast 2.4 on the inverted background.

// Contrast offset of WCAG 2.x (the 0.05 flare term).
const float WCAG_FLARE = 0.05;
// The constant of the mirror map: (1 + flare) * flare.
const float MIRROR_PRODUCT = (1.0 + WCAG_FLARE) * WCAG_FLARE;
// Below this peak channel a colour counts as black and has no direction to keep.
const float BLACK_PEAK = 1e-6;

// srgb_to_linear - decode sRGB (IEC 61966-2-1) into linear light, per channel.
vec3 srgb_to_linear(vec3 encoded) {
    // Linear toe below 0.04045, power curve above it.
    vec3 toe = encoded / 12.92;
    vec3 curve = pow((encoded + 0.055) / 1.055, vec3(2.4));
    return mix(curve, toe, vec3(lessThanEqual(encoded, vec3(0.04045))));
}

// linear_to_srgb - encode linear light as sRGB, per channel (the input is clamped to 0..1).
vec3 linear_to_srgb(vec3 linear) {
    // The same two pieces as above, inverted; pow() never sees a negative base.
    vec3 bounded = clamp(linear, 0.0, 1.0);
    vec3 toe = bounded * 12.92;
    vec3 curve = 1.055 * pow(bounded, vec3(1.0 / 2.4)) - 0.055;
    return mix(curve, toe, vec3(lessThanEqual(bounded, vec3(0.0031308))));
}

// apply_filter - mirror the relative luminance, keep the direction of the colour.
vec3 apply_filter(vec3 colour) {
    vec3 linear = srgb_to_linear(colour);
    float luminance = dot(linear, LUMA_WEIGHTS);
    float mirrored = MIRROR_PRODUCT / (luminance + WCAG_FLARE) - WCAG_FLARE;
    float peak = max(linear.r, max(linear.g, linear.b));
    // Black has no colour direction: it simply becomes the mirrored grey.
    if (peak < BLACK_PEAK) {
        return linear_to_srgb(vec3(mirrored));
    }
    // Scale the colour to the new luminance, but never past the brightest displayable channel.
    float scale = min(mirrored / luminance, 1.0 / peak);
    float scaled_luminance = scale * luminance;
    // A luminance the scale could not reach is added as white, which stays inside the gamut.
    float white_share = clamp((mirrored - scaled_luminance) / max(1.0 - scaled_luminance, 1e-6),
        0.0, 1.0);
    vec3 result = (1.0 - white_share) * scale * linear + vec3(white_share);
    return linear_to_srgb(result);
}
