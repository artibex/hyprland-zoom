"""Reference implementation of the colour filters, used to predict screenshot pixels.

The nested-Hyprland test compares what the GPU rendered (via grim) with these pure-Python
formulas, so a typo in a GLSL template shows up as a pixel mismatch.
Colours are tuples of three floats in 0..1 unless a function says otherwise.
"""

# Rec. 709 luma weights, identical to LUMA_WEIGHTS in src/shaders/base.glsl.
LUMA_WEIGHTS = (0.2126, 0.7152, 0.0722)

# Approximate display gamma of the daltonize maths (DISPLAY_GAMMA in cvd-common.glsl).
DISPLAY_GAMMA = 2.2

# Per deficiency: (simulation rows on linear RGB, error-shift rows), copied from filter-*.glsl.
# Simulation: Machado, Oliveira, Fernandes 2009 (severity 1.0); shift: Fidaner et al. 2005.
CVD_MATRICES = {
    "protanopia": (((0.152286, 1.052583, -0.204868), (0.114503, 0.786281, 0.099216),
                    (-0.003882, -0.048116, 1.051998)),
                   ((0.0, 0.0, 0.0), (0.7, 1.0, 0.0), (0.7, 0.0, 1.0))),
    "deuteranopia": (((0.367322, 0.860646, -0.227968), (0.280085, 0.672501, 0.047413),
                      (-0.011820, 0.042940, 0.968881)),
                     ((0.0, 0.0, 0.0), (0.7, 1.0, 0.0), (0.7, 0.0, 1.0))),
    "tritanopia": (((1.255528, -0.076749, -0.178779), (-0.078411, 0.930809, 0.147602),
                    (0.004733, 0.691367, 0.303900)),
                   ((1.0, 0.0, 0.7), (0.0, 1.0, 0.7), (0.0, 0.0, 0.0))),
}

# Constants of the smart-invert mirror map (see filter-smart-invert.glsl): the WCAG 2.x flare
# term, the map's constant (1 + flare) * flare and the peak below which a colour counts as black.
WCAG_FLARE = 0.05
MIRROR_PRODUCT = (1.0 + WCAG_FLARE) * WCAG_FLARE
BLACK_PEAK = 1e-6

# Default adjustment values; they equal the schema defaults of the FILTER_* keys.
DEFAULT_ADJUSTMENTS = {"intensity": 1.0, "contrast": 1.0, "brightness": 0.0, "saturation": 1.0}


def clamp01(value):
    """Limit a number to 0..1.

    Args:
        value: any float.

    Returns:
        The value clamped into the closed interval [0, 1].
    """
    # GLSL clamp(x, 0.0, 1.0) behaves exactly like this.
    return max(0.0, min(1.0, value))


def luma(colour):
    """Weighted brightness of a colour (Rec. 709).

    Args:
        colour: (r, g, b) floats.

    Returns:
        The luma as a float.
    """
    # Dot product with the shared weights.
    return sum(weight * channel for weight, channel in zip(LUMA_WEIGHTS, colour))


def multiply_rows(rows, vector):
    """Multiply a 3x3 matrix (given as rows) with a vector.

    Args:
        rows: three rows of three floats.
        vector: three floats.

    Returns:
        The product as a 3-tuple.
    """
    # Each output component is the dot product of one row with the vector.
    return tuple(sum(a * b for a, b in zip(row, vector)) for row in rows)


def daltonize(colour, name):
    """Daltonize-style correction for one colour-vision deficiency.

    Args:
        colour: (r, g, b) floats in 0..1 (gamma-encoded, as the screen shader sees them).
        name: protanopia, deuteranopia or tritanopia.

    Returns:
        The corrected colour, clamped to 0..1 and gamma-encoded again.
    """
    # Linearise, simulate the deficiency and take the error.
    simulation_rows, shift_rows = CVD_MATRICES[name]
    linear = tuple(channel ** DISPLAY_GAMMA for channel in colour)
    simulated = multiply_rows(simulation_rows, linear)
    lost = tuple(original - seen for original, seen in zip(linear, simulated))
    # Shift the lost information into visible channels, add it back and re-encode.
    shifted = multiply_rows(shift_rows, lost)
    corrected = tuple(clamp01(c + s) for c, s in zip(linear, shifted))
    return tuple(channel ** (1.0 / DISPLAY_GAMMA) for channel in corrected)


def srgb_to_linear(channel):
    """Decode one sRGB channel (IEC 61966-2-1) into linear light.

    Args:
        channel: encoded value in 0..1.

    Returns:
        Linear-light value in 0..1.
    """
    # Linear toe below 0.04045, power curve above it (srgb_to_linear in filter-smart-invert).
    if channel <= 0.04045:
        return channel / 12.92
    return ((channel + 0.055) / 1.055) ** 2.4


def linear_to_srgb(channel):
    """Encode one linear-light channel as sRGB.

    Args:
        channel: linear value (clamped into 0..1).

    Returns:
        Encoded value in 0..1.
    """
    # The two pieces of the sRGB curve, inverted.
    bounded = clamp01(channel)
    if bounded <= 0.0031308:
        return bounded * 12.92
    return 1.055 * bounded ** (1.0 / 2.4) - 0.055


def relative_luminance(colour):
    """WCAG 2.x relative luminance of an sRGB colour.

    Args:
        colour: (r, g, b) floats in 0..1, gamma-encoded.

    Returns:
        Luminance Y in 0..1.
    """
    # Weighted sum of the linear-light channels (the same weights as the shaders' luma).
    return luma(tuple(srgb_to_linear(channel) for channel in colour))


def contrast_ratio(first, second):
    """WCAG 2.x contrast ratio of two sRGB colours.

    Args:
        first: (r, g, b) floats in 0..1.
        second: (r, g, b) floats in 0..1.

    Returns:
        A ratio between 1 and 21.
    """
    # (lighter + 0.05) / (darker + 0.05), independent of the argument order.
    lighter, darker = sorted((relative_luminance(first), relative_luminance(second)),
                             reverse=True)
    return (lighter + WCAG_FLARE) / (darker + WCAG_FLARE)


def smart_invert(colour):
    """Mirror the relative luminance (WCAG contrast preserved), keep the colour direction.

    Args:
        colour: (r, g, b) floats in 0..1.

    Returns:
        The "dark mode" colour; the formulas are those of src/shaders/filter-smart-invert.glsl.
    """
    # Work in linear light, where luminance is a plain weighted sum.
    linear = tuple(srgb_to_linear(channel) for channel in colour)
    luminance = luma(linear)
    mirrored = MIRROR_PRODUCT / (luminance + WCAG_FLARE) - WCAG_FLARE
    peak = max(linear)
    # Black has no colour direction: it becomes the mirrored grey.
    if peak < BLACK_PEAK:
        return (linear_to_srgb(mirrored),) * 3
    # Scale to the new luminance, capped so the brightest channel stays displayable.
    scale = min(mirrored / luminance, 1.0 / peak)
    scaled_luminance = scale * luminance
    # Luminance the scale could not reach is added as white, which stays inside the gamut.
    white_share = clamp01((mirrored - scaled_luminance) / max(1.0 - scaled_luminance, 1e-6))
    return tuple(linear_to_srgb((1.0 - white_share) * scale * channel + white_share)
                 for channel in linear)


def smoothstep(low, high, value):
    """GLSL smoothstep for one number.

    Args:
        low: lower edge.
        high: upper edge.
        value: input.

    Returns:
        0 below low, 1 above high, a smooth ramp between.
    """
    # Normalise into 0..1, then apply the cubic Hermite curve.
    position = clamp01((value - low) / (high - low))
    return position * position * (3.0 - 2.0 * position)


def apply_filter(name, colour):
    """Apply the filter body of one named filter.

    Args:
        name: a FILTER enum value.
        colour: (r, g, b) floats in 0..1.

    Returns:
        The filtered colour (before intensity and adjustments).
    """
    # One branch per template in src/shaders/filter-*.glsl.
    if name == "invert":
        return tuple(1.0 - c for c in colour)
    if name == "smart-invert":
        return smart_invert(colour)
    # Greys use the shared luma weights.
    if name == "grayscale":
        return (luma(colour),) * 3
    if name == "grayscale-invert":
        # Inverted luma, same value in all three channels.
        return (1.0 - luma(colour),) * 3
    if name == "high-contrast":
        return tuple(smoothstep(0.25, 0.75, c) for c in colour)
    # Everything else is one of the three colour-vision corrections.
    return daltonize(colour, name)


def adjust(colour, contrast, brightness, saturation):
    """Contrast, brightness and saturation step after the filter.

    Args:
        colour: (r, g, b) floats.
        contrast: pivot-around-0.5 factor.
        brightness: additive shift.
        saturation: blend factor between grey and colour.

    Returns:
        The adjusted colour, clamped to 0..1.
    """
    # Same order as adjust_colour() in base.glsl.
    contrasted = tuple((c - 0.5) * contrast + 0.5 + brightness for c in colour)
    grey = luma(contrasted)
    return tuple(clamp01(grey + (c - grey) * saturation) for c in contrasted)


def expected_colour(name, rgb_bytes, adjustments=None):
    """Predict the screen colour of a source pixel under a filter.

    Args:
        name: a FILTER enum value, or "none" for the unfiltered screen.
        rgb_bytes: source colour as three 0..255 integers.
        adjustments: optional dict with intensity/contrast/brightness/saturation.

    Returns:
        The predicted colour as three 0..255 integers.
    """
    # No filter: the pixel is unchanged.
    if name == "none":
        return tuple(rgb_bytes)
    # Blend original and filtered colour by the intensity, then adjust.
    values = dict(DEFAULT_ADJUSTMENTS, **(adjustments or {}))
    source = tuple(channel / 255.0 for channel in rgb_bytes)
    filtered = apply_filter(name, source)
    mixed = tuple(s + (f - s) * values["intensity"] for s, f in zip(source, filtered))
    # Adjustments run after the blend, like main() in base.glsl.
    final = adjust(mixed, values["contrast"], values["brightness"], values["saturation"])
    return tuple(int(round(c * 255.0)) for c in final)
