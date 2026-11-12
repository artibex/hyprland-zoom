"""Unit tests of the Python shader reference (tests/integration/shader_reference.py).

The nested-Hyprland test compares screenshots with this reference, so the reference itself has to
be right: here the smart-invert filter is checked against the WCAG contrast requirement that
motivated its design (finding R-P1a-08).
"""

# Standard library only: random pairs and the unittest runner.
import os
import random
import sys
import unittest

# The reference module sits next to this file; make it importable however the tests start.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import shader_reference  # needs the sys.path entry above

# Smallest contrast ratio WCAG 2.x accepts for normal body text (level AA).
WCAG_AA_TEXT = 4.5
# Colours of the default link and of plain text on a white page.
LINK_BLUE = (0.0, 0.0, 238.0 / 255.0)
BLACK = (0.0, 0.0, 0.0)
WHITE = (1.0, 1.0, 1.0)


class SmartInvertContrastTest(unittest.TestCase):
    """The dark-mode filter must keep text readable."""

    def contrast_after_filter(self, text, background):
        """Contrast of two colours after both went through smart-invert.

        Args:
            text: (r, g, b) floats, the foreground.
            background: (r, g, b) floats, the page.

        Returns:
            The WCAG contrast ratio of the filtered pair.
        """
        # Both colours take the same path through the filter, like pixels on the real screen.
        filtered_text = shader_reference.smart_invert(text)
        filtered_background = shader_reference.smart_invert(background)
        return shader_reference.contrast_ratio(filtered_text, filtered_background)

    def test_blue_link_on_white_stays_readable(self):
        """#0000EE on white keeps at least AA contrast (the HSL flip gave 2.55)."""
        # Contrast before the filter is 9.4; the mirror map keeps it exactly.
        self.assertGreaterEqual(self.contrast_after_filter(LINK_BLUE, WHITE), WCAG_AA_TEXT)

    def test_black_on_white_stays_readable(self):
        """#000 on white keeps the maximum contrast."""
        # White text on a black page: 21:1 in both directions.
        self.assertGreaterEqual(self.contrast_after_filter(BLACK, WHITE), WCAG_AA_TEXT)

    def test_white_becomes_black_and_black_becomes_white(self):
        """The map is a plain inversion at the two ends of the range."""
        # Tolerance only covers float rounding.
        for source, expected in ((WHITE, BLACK), (BLACK, WHITE)):
            result = shader_reference.smart_invert(source)
            for channel, wanted in zip(result, expected):
                self.assertAlmostEqual(channel, wanted, places=6)

    def test_contrast_of_random_pairs_is_preserved(self):
        """Every pair keeps its contrast ratio (up to 1 %), not only black and white."""
        generator = random.Random(20260807)
        for _ in range(500):
            first = tuple(generator.random() for _ in range(3))
            second = tuple(generator.random() for _ in range(3))
            before = shader_reference.contrast_ratio(first, second)
            after = self.contrast_after_filter(first, second)
            # The mirror is exact in linear light; the tolerance covers the 8-bit-free float maths.
            self.assertAlmostEqual(after / before, 1.0, delta=0.01, msg=f"{first} {second}")

    def test_output_stays_inside_the_gamut(self):
        """No channel leaves 0..1, so nothing relies on clamping that would change contrast."""
        generator = random.Random(7)
        for _ in range(500):
            colour = tuple(generator.random() for _ in range(3))
            for channel in shader_reference.smart_invert(colour):
                self.assertTrue(0.0 <= channel <= 1.0, f"{colour} -> {channel}")

    def test_hue_direction_is_kept(self):
        """A pure blue stays blue-dominant after the filter (no flip to a complement)."""
        red, green, blue = shader_reference.smart_invert(LINK_BLUE)
        self.assertGreater(blue, red)
        self.assertGreater(blue, green)


if __name__ == "__main__":
    unittest.main()
