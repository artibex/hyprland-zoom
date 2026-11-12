"""Reference implementation of the colour filters, used to predict screenshot pixels.

The nested-Hyprland test compares what the GPU rendered (via grim) with these pure-Python
formulas, so a typo in a GLSL template shows up as a pixel mismatch.
Colours are tuples of three floats in 0..1 unless a function says otherwise.
"""

# colorsys gives HLS conversions, which are the HSL maths of the smart-invert shader.
import colorsys

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


def smart_invert(colour):
    """Invert the HSL lightness, keep hue and saturation.

    Args:
        colour: (r, g, b) floats in 0..1.

    Returns:
        The "dark mode" colour.
    """
    # colorsys returns hue, lightness, saturation (HLS order).
    hue, lightness, saturation = colorsys.rgb_to_hls(*colour)
    return colorsys.hls_to_rgb(hue, 1.0 - lightness, saturation)


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
    if name == "grayscale":
        return (luma(colour),) * 3
    if name == "grayscale-invert":
        return (1.0 - luma(colour),) * 3
    if name == "high-contrast":
        return tuple(smoothstep(0.25, 0.75, c) for c in colour)
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
    final = adjust(mixed, values["contrast"], values["brightness"], values["saturation"])
    return tuple(int(round(c * 255.0)) for c in final)
