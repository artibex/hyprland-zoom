"""Minimal PNG helpers for the nested-Hyprland camera measurement (stdlib only).

The test shows a coordinate-encoding gradient (red = x // 5, green = y // 3, blue = 128) on
the whole output. Whatever pattern pixel a screenshot pixel shows tells which part of the
pattern the zoom camera currently looks at.
"""

import struct
import zlib

# Gradient step sizes: one colour level per 5 px horizontally and 3 px vertically (255 levels
# cover the 1280x720 pattern), so a decoded coordinate is accurate to about +-2.5 / +-1.5 px.
X_STEP = 5
Y_STEP = 3
# The blue channel marks "this is the gradient", filtering out black borders and the cursor.
MARKER_BLUE = 128
# PNG signature, the fixed first eight bytes of every PNG file.
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def _chunk(kind: bytes, body: bytes) -> bytes:
    """Builds one PNG chunk.

    Args:
        kind: Four-byte chunk type.
        body: Chunk payload.

    Returns:
        Length + type + payload + CRC.
    """
    # The CRC covers type and payload, but not the length field.
    checksum = zlib.crc32(kind + body) & 0xFFFFFFFF
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", checksum)


def write_gradient(path: str, width: int = 1280, height: int = 720) -> None:
    """Writes the coordinate-encoding gradient as an 8-bit RGB PNG.

    Args:
        path: Output file.
        width: Pattern width, equal to the output width so imv shows it 1:1.
        height: Pattern height.
    """
    rows = []
    for y in range(height):
        # One scanline: filter byte 0 (none), then R,G,B per pixel.
        line = bytearray(b"\x00")
        for x in range(width):
            line += bytes((min(x // X_STEP, 255), min(y // Y_STEP, 255), MARKER_BLUE))
        rows.append(bytes(line))
    # IHDR: size, 8 bits per channel, colour type 2 (RGB), default compression/filter/interlace.
    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    png = PNG_SIGNATURE + _chunk(b"IHDR", header)
    # IDAT carries the zlib-compressed scanlines; IEND closes the file.
    png += _chunk(b"IDAT", zlib.compress(b"".join(rows), 6)) + _chunk(b"IEND", b"")
    with open(path, "wb") as png_file:
        png_file.write(png)


def _unfilter(raw: bytes, width: int, height: int, bytes_per_pixel: int) -> list:
    """Reverses PNG scanline filters.

    Args:
        raw: Decompressed IDAT data.
        width: Image width.
        height: Image height.
        bytes_per_pixel: 3 (RGB) or 4 (RGBA).

    Returns:
        One bytearray per scanline.
    """
    # Every scanline is one filter-type byte followed by `stride` data bytes.
    stride = width * bytes_per_pixel
    rows, previous, offset = [], bytearray(stride), 0
    for _ in range(height):
        # Filters refer to the previous scanline, which starts as all zeros.
        filter_type = raw[offset]
        line = bytearray(raw[offset + 1 : offset + 1 + stride])
        offset += 1 + stride
        for index in range(stride):
            # Neighbours: left (a), above (b), above-left (c); zero outside the image.
            left = line[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
            above = previous[index]
            corner = previous[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
            # The stored byte is the difference to the prediction, modulo 256.
            line[index] = (line[index] + _predict(filter_type, left, above, corner)) & 255
        rows.append(line)
        previous = line
    return rows


def _predict(filter_type: int, left: int, above: int, corner: int) -> int:
    """Returns the PNG filter predictor for one byte.

    Args:
        filter_type: 0 none, 1 sub, 2 up, 3 average, 4 Paeth.
        left: Byte to the left.
        above: Byte above.
        corner: Byte above-left.

    Returns:
        The value to add to the stored byte.
    """
    # Filters 1 to 3 predict from the neighbours directly.
    if filter_type == 1:
        return left
    # Up: the byte above; Average: the floor of the mean of left and above.
    if filter_type == 2:
        return above
    if filter_type == 3:
        return (left + above) >> 1
    if filter_type == 4:
        # Paeth: pick the neighbour closest to left + above - corner.
        distance_left = abs(above - corner)
        distance_above = abs(left - corner)
        distance_corner = abs(left + above - 2 * corner)
        # Ties resolve in the order left, above, corner, as the PNG specification demands.
        if distance_left <= distance_above and distance_left <= distance_corner:
            return left
        return above if distance_above <= distance_corner else corner
    # Filter 0 stores the byte unchanged.
    return 0


def read_png(path: str) -> tuple:
    """Decodes an 8-bit RGB/RGBA PNG (as written by grim).

    Args:
        path: PNG file.

    Returns:
        (width, height, bytes_per_pixel, rows) where rows[y] is a bytearray.
    """
    with open(path, "rb") as png_file:
        data = png_file.read()
    # Walk the chunks after the 8-byte signature, gathering the header and all IDAT data.
    position, compressed, width, height, color_type = 8, b"", 0, 0, 2
    while position < len(data):
        length, kind = struct.unpack(">I4s", data[position : position + 8])
        body = data[position + 8 : position + 8 + length]
        # IHDR gives size and colour type; IDAT chunks concatenate into one zlib stream.
        if kind == b"IHDR":
            width, height, bit_depth, color_type = struct.unpack(">IIBB", body[:10])
            assert bit_depth == 8, "only 8-bit PNGs are supported"
        elif kind == b"IDAT":
            # A PNG may split its image data over several IDAT chunks.
            compressed += body
        # Skip length, type, payload and the 4-byte CRC.
        position += 12 + length
    # Colour type 2 is RGB, 6 is RGBA (grim writes either depending on the build).
    bytes_per_pixel = {2: 3, 6: 4}[color_type]
    rows = _unfilter(zlib.decompress(compressed), width, height, bytes_per_pixel)
    return width, height, bytes_per_pixel, rows


def pixel(image: tuple, x: int, y: int) -> tuple:
    """Reads one RGB pixel (coordinates are clamped into the image).

    Args:
        image: Result of read_png.
        x: Column.
        y: Row.

    Returns:
        (red, green, blue).
    """
    width, height, bytes_per_pixel, rows = image
    # Clamping makes probes near the border safe instead of raising IndexError.
    x, y = min(max(x, 0), width - 1), min(max(y, 0), height - 1)
    offset = x * bytes_per_pixel
    return tuple(rows[y][offset : offset + 3])


def pattern_point(rgb: tuple) -> tuple | None:
    """Decodes which pattern point a pixel shows.

    Args:
        rgb: Pixel colour from a screenshot of the gradient.

    Returns:
        (x, y) in pattern pixels (centre of the colour step), or None when the blue marker is
        missing (border, cursor, filter, ...).
    """
    # Without the marker the pixel is not part of the gradient, so it carries no position.
    if rgb[2] != MARKER_BLUE:
        return None
    # Each colour level covers one step; the middle of the step is the best estimate.
    return rgb[0] * X_STEP + X_STEP / 2, rgb[1] * Y_STEP + Y_STEP / 2
