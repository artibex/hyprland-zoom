#!/usr/bin/env python3
"""PNG helper for the nested-Hyprland tests (standard library only).

Sub-commands:
  make <out.png> [width height]      write the test pattern (four colour quadrants + stripes)
  check <shot.png> <filter> [K=V..]  compare the four quadrant samples with the prediction
  stripe <shot.png> <y>              print the width of the widest white stripe on row y
Exit status 0 means success; `check` exits 1 and prints the mismatches otherwise.
"""

# Command-line parsing and output.
import sys
# PNG reading and writing needs zlib and struct only.
import struct
import zlib
# Pure-Python reference of the filters.
import shader_reference

# Quadrant colours of the test pattern: top-left, top-right, bottom-left, bottom-right.
QUADRANT_COLOURS = ((200, 40, 40), (40, 200, 40), (40, 40, 200), (200, 200, 40))
# Pixels to sample (away from the screen centre where the pointer sits), one per quadrant.
SAMPLE_POINTS = ((100, 100), (1100, 100), (100, 600), (1100, 600))
# Stripes: 40 px white every 160 px inside this band of rows.
STRIPE_PERIOD, STRIPE_WIDTH, STRIPE_TOP, STRIPE_BOTTOM = 160, 40, 300, 420
# Largest accepted difference per channel (8-bit rounding in the GPU and in grim).
TOLERANCE = 3


def write_png(path, width, height, rows):
    """Write an 8-bit RGB PNG.

    Args:
        path: output file path.
        width: image width in pixels.
        height: image height in pixels.
        rows: list of `height` byte strings with `width * 3` bytes each.

    Returns:
        None.
    """
    # Filter type 0 (none) in front of every scanline.
    raw = b"".join(b"\x00" + row for row in rows)

    def chunk(kind, body):
        """Build one PNG chunk (length, type, body, CRC)."""
        # The CRC covers type and body.
        crc = struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)
        return struct.pack(">I", len(body)) + kind + body + crc

    # Header: 8-bit depth, colour type 2 (RGB), no interlace.
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
    png += chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b"")
    with open(path, "wb") as handle:
        # Write the finished file in one go.
        handle.write(png)


def paeth(left, above, upper_left):
    """PNG Paeth predictor.

    Args:
        left: byte to the left.
        above: byte above.
        upper_left: byte above-left.

    Returns:
        The predicted byte value.
    """
    # Pick the neighbour closest to the linear estimate.
    estimate = left + above - upper_left
    distances = (abs(estimate - left), abs(estimate - above), abs(estimate - upper_left))
    return (left, above, upper_left)[distances.index(min(distances))]


def unfilter_scanline(kind, line, previous, bytes_per_pixel):
    """Undo one PNG scanline filter in place.

    Args:
        kind: filter type 0..4.
        line: bytearray of the filtered scanline (modified).
        previous: the already unfiltered scanline above.
        bytes_per_pixel: 3 (RGB) or 4 (RGBA).

    Returns:
        The same bytearray, unfiltered.
    """
    # Each byte depends on its left neighbour, the byte above and the upper-left one.
    for index in range(len(line)):
        left = line[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
        above = previous[index]
        upper_left = previous[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
        # The predictor for filter types 0..4 (none, left, up, average, Paeth).
        predictor = (0, left, above, (left + above) >> 1, paeth(left, above, upper_left))[kind]
        line[index] = (line[index] + predictor) & 255
    return line


def read_png(path):
    """Decode an 8-bit RGB or RGBA PNG.

    Args:
        path: PNG file path.

    Returns:
        (width, height, bytes_per_pixel, rows) where rows are bytearrays.
    """
    # Collect the IDAT chunks and the header fields.
    with open(path, "rb") as handle:
        data = handle.read()
    position, compressed, colour_type, width, height = 8, b"", 2, 0, 0
    while position < len(data):
        # Every chunk starts with its body length and a four-letter type.
        length, kind = struct.unpack(">I4s", data[position:position + 8])
        body = data[position + 8:position + 8 + length]
        if kind == b"IHDR":
            # The header chunk carries the image size and the colour type.
            width, height = struct.unpack(">II", body[:8])
            colour_type = body[9]
        elif kind == b"IDAT":
            # Image data may be split over several IDAT chunks; join them.
            compressed += body
        position += 12 + length
    # Colour type 2 is RGB, 6 is RGBA; both with 8 bits per channel.
    bytes_per_pixel = {2: 3, 6: 4}[colour_type]
    raw = zlib.decompress(compressed)
    stride = width * bytes_per_pixel
    rows, previous = [], bytearray(stride)
    # Each scanline is one filter byte plus `stride` data bytes.
    for row_index in range(height):
        start = row_index * (stride + 1)
        line = bytearray(raw[start + 1:start + 1 + stride])
        # The unfiltered line is the reference for the next one.
        previous = unfilter_scanline(raw[start], line, previous, bytes_per_pixel)
        rows.append(previous)
    return width, height, bytes_per_pixel, rows


def pixel_at(image, x, y):
    """Read one pixel of a decoded image.

    Args:
        image: tuple from read_png.
        x: column.
        y: row.

    Returns:
        (r, g, b) integers; coordinates outside the image are clamped to its edge.
    """
    # Clamp so a slightly different screenshot size cannot raise.
    width, height, bytes_per_pixel, rows = image
    column = min(max(x, 0), width - 1) * bytes_per_pixel
    return tuple(rows[min(max(y, 0), height - 1)][column:column + 3])


def pattern_colour(x, y, width, height):
    """Colour of the test pattern at one position.

    Args:
        x: column.
        y: row.
        width: image width.
        height: image height.

    Returns:
        (r, g, b) integers.
    """
    # White stripes inside the band, otherwise the quadrant colour.
    in_band = STRIPE_TOP < y < STRIPE_BOTTOM
    if in_band and (x // STRIPE_WIDTH) % (STRIPE_PERIOD // STRIPE_WIDTH) == 0:
        return (255, 255, 255)
    return QUADRANT_COLOURS[(1 if x >= width // 2 else 0) + (2 if y >= height // 2 else 0)]


def make_pattern(path, width=1280, height=720):
    """Write the test pattern PNG.

    Args:
        path: output file path.
        width: image width.
        height: image height.

    Returns:
        None.
    """
    # Build every scanline from the pattern function.
    rows = [b"".join(bytes(pattern_colour(x, y, width, height)) for x in range(width))
            for y in range(height)]
    write_png(path, width, height, rows)


def parse_adjustments(arguments):
    """Turn KEY=VALUE arguments into an adjustments dict.

    Args:
        arguments: strings such as "contrast=1.5".

    Returns:
        dict of lower-case keys to floats.
    """
    # Only numeric values are accepted.
    pairs = (argument.split("=", 1) for argument in arguments)
    return {key.lower(): float(value) for key, value in pairs}


def check_filter(path, filter_name, adjustments):
    """Compare the four sample pixels of a screenshot with the filter prediction.

    Args:
        path: screenshot PNG path.
        filter_name: FILTER enum value or "none".
        adjustments: dict for shader_reference.expected_colour.

    Returns:
        List of mismatch descriptions (empty when everything matches).
    """
    # One sample per quadrant; the expectation starts from the known pattern colour.
    image = read_png(path)
    problems = []
    for (x, y), source in zip(SAMPLE_POINTS, QUADRANT_COLOURS):
        expected = shader_reference.expected_colour(filter_name, source, adjustments)
        # Compare the worst channel difference with the tolerance.
        actual = pixel_at(image, x, y)
        if max(abs(a - e) for a, e in zip(actual, expected)) > TOLERANCE:
            problems.append(f"({x},{y}) {filter_name}: expected {expected}, got {actual}")
    # An empty list means every sample matched.
    return problems


def stripe_width(path, y):
    """Measure the widest white stripe on one row (stripes cut by the screen edge are narrower).

    Args:
        path: screenshot PNG path.
        y: row to scan.

    Returns:
        Width of the longest run of white pixels in pixels (0 when there is none).
    """
    # Walk the row once, tracking the current and the longest run of white pixels.
    image = read_png(path)
    longest = current = 0
    for x in range(image[0]):
        current = current + 1 if pixel_at(image, x, y) == (255, 255, 255) else 0
        # Keep the longest run seen so far.
        longest = max(longest, current)
    return longest


def main(arguments):
    """Command-line entry point.

    Args:
        arguments: argv without the program name.

    Returns:
        Process exit status.
    """
    # Dispatch on the sub-command; anything else prints the module help.
    command = arguments[0] if arguments else ""
    if command == "make":
        make_pattern(arguments[1], *(int(value) for value in arguments[2:4]))
        return 0
    # Compare a screenshot with a filter prediction.
    if command == "check":
        problems = check_filter(arguments[1], arguments[2], parse_adjustments(arguments[3:]))
        print("\n".join(problems) if problems else "OK")
        # Non-zero status lets the shell test count a failure.
        return 1 if problems else 0
    if command == "stripe":
        print(stripe_width(arguments[1], int(arguments[2])))
        # Measuring never fails; the caller compares the number.
        return 0
    print(__doc__)
    return 2


# Run only when executed as a script, not when imported.
if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
