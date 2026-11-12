"""Display-free tests of the pure model: schema, values, keys, porcelain, presentation."""

# unittest is the runner; support sets up the import path and loads the real schema.
import unittest

import support

from hyprland_zoom_settings import keys, porcelain, presentation, values
from hyprland_zoom_settings.schema import SchemaError, parse_schema


def real_schema():
    """Parse the contract schema.

    Returns:
        The SettingsSchema of ``config/settings.schema``.
    """
    # Every test class shares the same parse of the real file.
    return parse_schema(support.read_schema_text())


class SchemaTests(unittest.TestCase):
    """The schema parser against the real contract file and malformed input."""

    def test_real_schema_parses_with_all_keys_and_five_groups(self):
        """The contract schema yields typed specs for every line."""
        schema = real_schema()
        # Five groups appear in the contract; ZOOM_STEP is the first float with a range.
        self.assertEqual(
            set(schema.group_ids()), {"zoom", "tracking", "filter", "shortcuts", "advanced"}
        )
        step = schema.by_key["ZOOM_STEP"]
        self.assertEqual((step.kind, step.minimum, step.maximum), ("float", 0.01, 2.0))

    def test_enum_choices_and_bool_without_constraint(self):
        """Enum constraints become choice tuples; bools have none."""
        schema = real_schema()
        self.assertIn("smart-invert", schema.by_key["FILTER"].choices)
        self.assertEqual(schema.by_key["ZOOM_SMOOTH_IMAGES"].choices, ())

    def test_group_membership_keeps_schema_order(self):
        """Settings of a group come in file order."""
        keys_in_zoom = [spec.key for spec in real_schema().specs_in_group("zoom")]
        self.assertEqual(keys_in_zoom[:2], ["ZOOM_STEP", "ZOOM_STEP_MODE"])

    def test_help_text_may_contain_pipes(self):
        """Only the first six separators split fields."""
        schema = parse_schema("A|bool|on||zoom|Label|help | with pipe")
        self.assertEqual(schema.by_key["A"].help, "help | with pipe")

    def test_malformed_lines_raise(self):
        """Too few fields, unknown types and duplicates are rejected."""
        for bad in ("A|bool|on", "A|blob|x||g|l|h", "A|float|1||g|l|h"):
            with self.assertRaises(SchemaError, msg=bad):
                parse_schema(bad)
        with self.assertRaises(SchemaError):
            parse_schema("A|bool|on||g|l|h\nA|bool|on||g|l|h")

    def test_comments_and_blank_lines_are_ignored(self):
        """Comment and blank lines carry no setting."""
        self.assertEqual(parse_schema("# note\n\n  # more\n").specs, [])

    def test_defaults_pass_their_own_validation(self):
        """Every schema default is valid and already canonical."""
        for spec in real_schema().specs:
            verdict = values.check_value(spec, spec.default)
            self.assertTrue(verdict.ok, spec.key)
            # Canonical form of the default is the default (the key type upper-cases).
            self.assertEqual(verdict.canonical, spec.default, spec.key)


class ValueTests(unittest.TestCase):
    """Value validation and canonical formatting."""

    def setUp(self):
        """Load the schema once per test."""
        self.schema = real_schema()

    def check(self, key, text):
        """Validate a value for a schema key.

        Args:
            key: Schema key.
            text: Candidate text.

        Returns:
            The ValueCheck.
        """
        # Thin wrapper keeps the assertions short.
        return values.check_value(self.schema.by_key[key], text)

    def test_float_canonical_two_decimals(self):
        """Floats are rounded to two decimals."""
        self.assertEqual(self.check("ZOOM_STEP", "0.1").canonical, "0.10")
        self.assertEqual(self.check("ZOOM_STEP", " 0.125 ").canonical, "0.12")

    def test_float_range_is_enforced_on_the_rounded_value(self):
        """Out-of-range floats are refused with a readable message."""
        verdict = self.check("ZOOM_STEP", "2.5")
        self.assertFalse(verdict.ok)
        self.assertIn("between 0.01 and 2.00", verdict.error)
        self.assertFalse(self.check("ZOOM_STEP", "0.001").ok)

    def test_not_a_number_and_non_finite_are_refused(self):
        """Garbage, NaN and infinity never reach zoomctl."""
        for text in ("abc", "", "nan", "inf", "1e999"):
            self.assertFalse(self.check("ZOOM_STEP", text).ok, text)

    def test_negative_zero_is_normalised(self):
        """Brightness -0.001 is stored as 0.00."""
        self.assertEqual(self.check("FILTER_BRIGHTNESS", "-0.001").canonical, "0.00")

    def test_int_accepts_whole_numbers_only(self):
        """The scroll delay is a whole number of milliseconds."""
        self.assertEqual(self.check("SCROLL_EVENT_DELAY_MS", "120").canonical, "120")
        self.assertFalse(self.check("SCROLL_EVENT_DELAY_MS", "12.5").ok)
        self.assertFalse(self.check("SCROLL_EVENT_DELAY_MS", "301").ok)

    def test_bool_aliases_become_on_off(self):
        """All CLI aliases normalise to on/off."""
        for text, expected in (("1", "on"), ("TRUE", "on"), ("no", "off"), ("off", "off")):
            self.assertEqual(self.check("ZOOM_SMOOTH_IMAGES", text).canonical, expected)
        self.assertFalse(self.check("ZOOM_SMOOTH_IMAGES", "maybe").ok)

    def test_enum_is_lowercased_and_checked(self):
        """Enum values must be one of the choices."""
        self.assertEqual(self.check("ZOOM_TRACKING", "Margin").canonical, "margin")
        verdict = self.check("ZOOM_TRACKING", "diagonal")
        self.assertFalse(verdict.ok)
        self.assertIn("centered, edge, margin, follow", verdict.error)

    def test_key_names_are_uppercased_and_may_be_empty(self):
        """Keys are keysym names; empty disables the bind; punctuation is refused."""
        self.assertEqual(self.check("BIND_KEY_IN", "i").canonical, "I")
        self.assertEqual(self.check("BIND_KEY_IN", "").canonical, "")
        for text in ("a b", "x;y", "$(id)", "a" * 40):
            self.assertFalse(self.check("BIND_KEY_IN", text).ok, text)

    def test_modifiers_are_canonical_ordered_and_deduplicated(self):
        """Modifier lists are normalised; empty and unknown lists are refused."""
        verdict = self.check("BIND_MODIFIERS", "alt+super + ALT")
        self.assertEqual(verdict.canonical, "SUPER + ALT")
        self.assertEqual(self.check("BIND_MODIFIERS", "Control+Shift").canonical, "CTRL + SHIFT")
        self.assertFalse(self.check("BIND_MODIFIERS", "").ok)
        self.assertFalse(self.check("BIND_MODIFIERS", "SUPER + HYPER").ok)

    def test_helpers(self):
        """format_float, parse_bool and float_digits."""
        self.assertEqual(values.format_float(1.5), "1.50")
        self.assertIsNone(values.parse_bool("x"))
        self.assertEqual(values.float_digits(self.schema.by_key["ZOOM_STEP"]), 2)
        self.assertEqual(values.float_digits(self.schema.by_key["SCROLL_EVENT_DELAY_MS"]), 0)


class KeyTests(unittest.TestCase):
    """Key capture mapping, accelerator text and conflicts."""

    def test_letters_digits_and_named_keys(self):
        """GDK keysym names become upper-case Hyprland names."""
        cases = {"i": "I", "0": "0", "F5": "F5", "Return": "RETURN", "space": "SPACE",
                 "minus": "MINUS", "ISO_Left_Tab": "TAB", "Left": "LEFT"}
        for keysym, expected in cases.items():
            self.assertEqual(keys.hyprland_key_name(keysym), expected, keysym)

    def test_modifiers_escape_and_unknown_are_not_bindable(self):
        """Lone modifiers, the cancel key and missing names give None."""
        for keysym in ("Shift_L", "Super_R", "Caps_Lock", "Escape", "", None):
            self.assertIsNone(keys.hyprland_key_name(keysym), keysym)

    def test_chord_parts_for_the_keycap_strip(self):
        """The strip shows modifiers then the key; disabled binds show nothing."""
        self.assertEqual(keys.chord_parts("SUPER + ALT", "I"), ["Super", "Alt", "I"])
        self.assertEqual(keys.chord_parts("CTRL + SHIFT", "RETURN"), ["Ctrl", "Shift", "Return"])
        self.assertEqual(keys.chord_parts("SUPER", ""), [])
        self.assertEqual(keys.chord_parts("bogus", "F5"), ["F5"])

    def test_conflict_detection_ignores_self_and_empty(self):
        """Another key-typed setting with the same key is reported."""
        schema = real_schema()
        config = schema.defaults()
        conflict = keys.find_key_conflict(schema, config, "BIND_KEY_OUT", "I")
        self.assertEqual(conflict.key, "BIND_KEY_IN")
        self.assertIsNone(keys.find_key_conflict(schema, config, "BIND_KEY_IN", "I"))
        self.assertIsNone(keys.find_key_conflict(schema, config, "BIND_KEY_OUT", ""))
        self.assertIsNone(keys.find_key_conflict(schema, config, "BIND_KEY_OUT", "P"))


class PorcelainTests(unittest.TestCase):
    """Porcelain parsing and the status line."""

    def test_key_values_ignore_noise_and_keep_equals_in_values(self):
        """Comments, blank lines and lines without '=' are skipped."""
        pairs = porcelain.parse_key_values("# c\n\nA=1\nbroken\nB = x=y \n=empty\n")
        self.assertEqual(pairs, {"A": "1", "B": "x=y"})

    def test_status_parsed_into_typed_fields(self):
        """Contract C6 keys map to the typed status; unknown keys are ignored."""
        status = porcelain.parse_status(
            "engine=lua\nzoom=1.50\ntracking=margin\ntracking_effective=edge\n"
            "plugin=missing\nfilter=grayscale\nfilter_active=on\nfuture=1\n"
        )
        self.assertEqual((status.engine, status.zoom), ("lua", 1.5))
        self.assertTrue(status.filter_active)
        self.assertFalse(status.plugin_loaded)
        self.assertFalse(status.engine_missing)

    def test_bad_numbers_and_empty_output_degrade_gracefully(self):
        """No crash on junk; empty output means an unreachable engine."""
        self.assertIsNone(porcelain.parse_status("zoom=abc\nengine=lua").zoom)
        empty = porcelain.parse_status("")
        self.assertEqual(empty.engine, porcelain.ENGINE_UNREACHABLE)
        self.assertEqual(porcelain.describe_status(empty), "zoomctl is not answering")

    def test_missing_engine_is_detected(self):
        """The banner trigger is engine=missing."""
        self.assertTrue(porcelain.parse_status("engine=missing").engine_missing)

    def test_describe_status_mentions_configured_tracking_when_it_differs(self):
        """A margin request that falls back to edge is explained in the line."""
        status = porcelain.parse_status(
            "engine=lua\nzoom=2\ntracking=margin\ntracking_effective=edge\nfilter=invert\n"
        )
        line = porcelain.describe_status(status)
        self.assertIn("Zoom 2.00×", line)
        self.assertIn("edge (configured: margin)", line)
        self.assertIn("Engine: lua", line)


class PresentationTests(unittest.TestCase):
    """Page order and option labels."""

    def test_known_groups_follow_presentation_order_not_schema_order(self):
        """The schema mentions 'advanced' early; the page order keeps it last."""
        order = presentation.ordered_groups(real_schema().group_ids())
        self.assertEqual(
            [info.group for info in order],
            ["zoom", "tracking", "filter", "shortcuts", "advanced"],
        )

    def test_unknown_group_gets_a_generated_page(self):
        """A group the app does not know is appended with a humanised title."""
        order = presentation.ordered_groups(["zoom", "audio-cues"])
        self.assertEqual(order[-1].title, "Audio cues")

    def test_option_labels_and_fallbacks(self):
        """Hand-written labels win; unknown options are humanised."""
        self.assertEqual(presentation.option_label("FILTER", "smart-invert"), "Smart invert")
        self.assertEqual(presentation.option_label("FILTER", "sepia-warm"), "Sepia warm")
        self.assertIsNone(presentation.option_description("FILTER", "sepia-warm"))

    def test_every_schema_enum_option_has_hand_written_text(self):
        """New schema options without presentation text must be noticed here."""
        for spec in real_schema().specs:
            for option in spec.choices:
                self.assertIsNotNone(
                    presentation.option_description(spec.key, option), f"{spec.key}={option}"
                )


if __name__ == "__main__":
    unittest.main()
