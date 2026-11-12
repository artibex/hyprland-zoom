// filter-smart-invert - "dark mode" look: invert the HSL lightness, keep hue and saturation.
// White becomes black while reds stay red-ish and photos remain recognisable.

// rgb_to_hsl - convert RGB (0..1) to hue, saturation, lightness (all 0..1).
vec3 rgb_to_hsl(vec3 colour) {
    // Lightness is the middle of the largest and smallest channel.
    float highest = max(colour.r, max(colour.g, colour.b));
    float lowest = min(colour.r, min(colour.g, colour.b));
    float lightness = 0.5 * (highest + lowest);
    float spread = highest - lowest;
    float hue = 0.0;
    float saturation = 0.0;
    // Greys (no spread) keep hue and saturation 0 and avoid a division by zero.
    if (spread > 1e-5) {
        saturation = spread / (1.0 - abs(2.0 * lightness - 1.0));
        // The hue sector depends on which channel is the largest.
        if (highest == colour.r) {
            hue = mod((colour.g - colour.b) / spread, 6.0);
        } else if (highest == colour.g) {
            hue = (colour.b - colour.r) / spread + 2.0;
        } else {
            hue = (colour.r - colour.g) / spread + 4.0;
        }
        hue /= 6.0;
    }
    return vec3(hue, saturation, lightness);
}

// hsl_to_rgb - convert hue, saturation, lightness back to RGB.
vec3 hsl_to_rgb(vec3 hsl) {
    // Chroma and the second-largest component of the colour at this hue.
    float sector = hsl.x * 6.0;
    float chroma = (1.0 - abs(2.0 * hsl.z - 1.0)) * hsl.y;
    float second = chroma * (1.0 - abs(mod(sector, 2.0) - 1.0));
    float match_lightness = hsl.z - 0.5 * chroma;
    vec3 rgb;
    // Pick the RGB permutation of the hue sector.
    if (sector < 1.0) {
        rgb = vec3(chroma, second, 0.0);
    } else if (sector < 2.0) {
        rgb = vec3(second, chroma, 0.0);
    } else if (sector < 3.0) {
        rgb = vec3(0.0, chroma, second);
    } else if (sector < 4.0) {
        rgb = vec3(0.0, second, chroma);
    } else if (sector < 5.0) {
        rgb = vec3(second, 0.0, chroma);
    } else {
        rgb = vec3(chroma, 0.0, second);
    }
    return rgb + match_lightness;
}

vec3 apply_filter(vec3 colour) {
    // Flip only the lightness; hue and saturation keep the colour identity.
    vec3 hsl = rgb_to_hsl(colour);
    hsl.z = 1.0 - hsl.z;
    return hsl_to_rgb(hsl);
}
