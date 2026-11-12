"""Display-free tests of the pure model: schema, values, keys, porcelain, presentation."""

# unittest is the runner; support sets up the import path and loads the real schema.
import unittest

import support

from hyprland_zoom_settings import keys, messages, porcelain, presentation, sizing, values
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
        # A repeated key is the one error that needs two lines to provoke.
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
        # 0.001 rounds to 0.00, which is below the minimum.
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
        # The message must list the valid choices so the user can fix it.
        self.assertIn("centered, edge, margin, follow", verdict.error)

    def test_key_names_are_uppercased_and_may_be_empty(self):
        """Keys are keysym names; empty disables the bind; punctuation is refused."""
        self.assertEqual(self.check("BIND_KEY_IN", "i").canonical, "I")
        self.assertEqual(self.check("BIND_KEY_IN", "").canonical, "")
        for text in ("a b", "x;y", "$(id)", "a" * 40):
            # Spaces, separators, shell syntax and over-long names are all refused.
            self.assertFalse(self.check("BIND_KEY_IN", text).ok, text)

    def test_modifiers_are_canonical_ordered_and_deduplicated(self):
        """Modifier lists are normalised; empty and unknown lists are refused."""
        verdict = self.check("BIND_MODIFIERS", "alt+super + ALT")
        self.assertEqual(verdict.canonical, "SUPER + ALT")
        # The order is zoomctl's own (SUPER, SHIFT, CTRL, ALT), so both tools write one text.
        self.assertEqual(self.check("BIND_MODIFIERS", "Control+Shift").canonical, "CTRL + SHIFT")
        self.assertEqual(self.check("BIND_MODIFIERS", "alt + ctrl + super").canonical,
                         "SUPER + CTRL + ALT")
        # No modifier at all and an unknown modifier are both invalid.
        self.assertFalse(self.check("BIND_MODIFIERS", "").ok)
        self.assertFalse(self.check("BIND_MODIFIERS", "SUPER + HYPER").ok)

    def test_helpers(self):
        """format_float, parse_bool and float_digits."""
        self.assertEqual(values.format_float(1.5), "1.50")
        self.assertIsNone(values.parse_bool("x"))
        self.assertEqual(values.float_digits(self.schema.by_key["ZOOM_STEP"]), 2)
        # Whole-number settings show no decimals.
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
        # Unknown modifier text degrades to the key alone.
        self.assertEqual(keys.chord_parts("bogus", "F5"), ["F5"])

    def test_conflict_detection_ignores_self_and_empty(self):
        """Another key-typed setting with the same key is reported."""
        schema = real_schema()
        config = schema.defaults()
        conflict = keys.find_key_conflict(schema, config, "BIND_KEY_OUT", "I")
        # The conflict names the other setting, so the toast can say which.
        self.assertEqual(conflict.key, "BIND_KEY_IN")
        self.assertIsNone(keys.find_key_conflict(schema, config, "BIND_KEY_IN", "I"))
        self.assertIsNone(keys.find_key_conflict(schema, config, "BIND_KEY_OUT", ""))
        # A key nobody uses is free.
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
        # plugin=missing means margin mode is unavailable.
        self.assertFalse(status.plugin_loaded)
        self.assertFalse(status.engine_missing)

    def test_bad_numbers_and_empty_output_degrade_gracefully(self):
        """No crash on junk; empty output means an unreachable engine."""
        self.assertIsNone(porcelain.parse_status("zoom=abc\nengine=lua").zoom)
        empty = porcelain.parse_status("")
        self.assertEqual(empty.engine, porcelain.ENGINE_UNREACHABLE)
        # The unreachable state has its own sentence.
        self.assertEqual(porcelain.describe_status(empty), "zoomctl is not answering")

    def test_missing_engine_is_detected(self):
        """The banner trigger is engine=missing."""
        self.assertTrue(porcelain.parse_status("engine=missing").engine_missing)

    def test_status_line_is_friendly_and_names_the_engine_only_when_unusual(self):
        """Plain words, no raw ids, no 'Engine: lua'."""
        status = porcelain.parse_status(
            "engine=lua\nzoom=1.50\ntracking=centered\ntracking_effective=centered\n"
            "filter=smart-invert\nfilter_active=on\n"
        )
        self.assertEqual(porcelain.describe_status(status),
                         "Zoom 1.5× · Pointer centered · Smart invert on")
        # An inactive filter is just "off"; a whole number loses its decimals.
        off = porcelain.parse_status("engine=lua\nzoom=2.00\ntracking=edge\nfilter_active=off")
        self.assertEqual(porcelain.describe_status(off),
                         "Zoom 2× · View moves at the edge · Color filter off")
        legacy = porcelain.parse_status("engine=legacy\nhyprland=0.56.2\nzoom=1\ntracking=edge")
        self.assertIn("Compatibility mode (limited)", porcelain.describe_status(legacy))

    def test_status_line_before_the_first_answer_and_without_a_compositor(self):
        """'Checking…' is neutral; an unreachable Hyprland is told apart from setup."""
        self.assertEqual(porcelain.describe_status(porcelain.EngineStatus(), received=False),
                         "Checking…")
        # An unreachable compositor is told apart from a missing setup.
        gone = porcelain.parse_status("engine=missing\nhyprland=unknown")
        self.assertEqual(gone.state, porcelain.STATE_NO_HYPRLAND)
        self.assertEqual(porcelain.describe_status(gone), "Hyprland is not reachable")
        # With a reachable compositor the same answer means: set it up.
        unset = porcelain.parse_status("engine=missing\nhyprland=0.56.2")
        self.assertEqual(unset.state, porcelain.STATE_NEEDS_SETUP)

    def test_engine_states(self):
        """Every engine answer maps to exactly one window state."""
        states = {
            "engine=lua": porcelain.STATE_READY,
            "engine=legacy\nhyprland=0.56.2": porcelain.STATE_COMPATIBILITY,
            "": porcelain.STATE_NO_ZOOMCTL,
        }
        for text, expected in states.items():
            self.assertEqual(porcelain.parse_status(text).state, expected, text)

    def test_tracking_notice_only_when_hyprland_differs_and_in_plain_words(self):
        """Margin without the plugin gets ONE notice that offers the installation."""
        base = "engine=lua\nhyprland=0.56.2\n"
        missing = porcelain.parse_status(base + "tracking_effective=edge\nplugin=missing")
        # Margin without the plugin offers the installation.
        notice = porcelain.tracking_notice("margin", missing)
        self.assertTrue(notice.needs_plugin)
        self.assertIn("Edge with a fixed 5 % margin", notice.body)
        # No raw identifiers in the sentence.
        self.assertNotIn("tracking", notice.body)
        # With the plugin loaded there is nothing to explain.
        loaded = porcelain.parse_status(base + "tracking_effective=margin\nplugin=loaded")
        self.assertIsNone(porcelain.tracking_notice("margin", loaded))
        # Another mode that works as configured needs no words either.
        centered = porcelain.parse_status(base + "tracking_effective=centered\nplugin=missing")
        self.assertIsNone(porcelain.tracking_notice("centered", centered))
        # Unknown state: nothing to explain yet.
        self.assertIsNone(porcelain.tracking_notice("margin", porcelain.EngineStatus()))


class MessageTests(unittest.TestCase):
    """Plain-language mapping of zoomctl messages."""

    def test_known_messages_become_plain_sentences_with_details(self):
        """The prefix and the jargon are gone; the raw text stays as details."""
        notice = messages.friendly_notice(
            "zoomctl: saved, but the engine rejected the reload: error: unknown key"
        )
        # The jargon is replaced; the raw text stays as details.
        self.assertEqual(notice.summary, "Saved, but Hyprland could not apply the change.")
        self.assertIn("engine rejected the reload", notice.details)
        # Offline notes are plain too.
        offline = messages.friendly_notice("zoomctl: engine not reachable, saved only")
        self.assertIn("Hyprland is not reachable", offline.summary)

    def test_backup_notes_are_log_only(self):
        """Path-heavy bookkeeping never becomes a toast."""
        notice = messages.friendly_notice(
            "zoomctl: backup of /home/u/hyprland.lua saved as /home/u/hyprland.lua.bak"
        )
        self.assertEqual(notice.summary, "")

    def test_unknown_messages_lose_the_prefix_and_long_or_path_texts_are_hidden(self):
        """Short text is shown capitalized, path-heavy or long text is replaced."""
        self.assertEqual(messages.friendly_notice("zoomctl: something odd").summary,
                         "Something odd")
        # Path-heavy text is replaced by a generic sentence plus details.
        long_text = "zoomctl: cannot read /etc/zoomctl/a/b/c because of a very strange reason"
        notice = messages.friendly_notice(long_text)
        # The raw text stays available.
        self.assertEqual(notice.summary, "zoomctl reported a problem.")
        self.assertIn("/etc/zoomctl", notice.details)

    def test_zoom_range_rule_message_is_plain(self):
        """The cross-field message of zoomctl is replaced by a sentence without key names."""
        notice = messages.friendly_notice(
            "zoomctl: ZOOM_MIN (5.00) <= ZOOM_RESET (1.00) <= ZOOM_MAX (10.00) must hold"
        )
        self.assertNotIn("ZOOM_", notice.summary)


class CrossFieldTests(unittest.TestCase):
    """The local MIN <= RESET <= MAX check with labels."""

    def test_violations_name_the_settings_by_label(self):
        """Min above reset is refused with both labels and the current value."""
        schema = real_schema()
        labels = {spec.key: spec.label for spec in schema.specs}
        # The defaults are MIN 1, RESET 1, MAX 10.
        config = schema.defaults()
        message = values.check_zoom_order(labels, config, "ZOOM_MIN", "2.00")
        self.assertEqual(message, "Minimum zoom (2.00) can't be above Reset zoom (1.00)")
        # A change that keeps the order, and an unrelated key, pass.
        self.assertEqual(values.check_zoom_order(labels, config, "ZOOM_MAX", "5.00"), "")
        self.assertEqual(values.check_zoom_order(labels, config, "ZOOM_STEP", "0.5"), "")


class LayoutTests(unittest.TestCase):
    """The window size follows the text scale."""

    def test_default_size_grows_with_text_and_stays_on_the_monitor(self):
        """164 % text gets a bigger window; a small monitor caps it."""
        normal = sizing.default_window_size(1.0, None)
        large = sizing.default_window_size(1.64, None)
        # Larger text gets a larger window in both directions.
        self.assertGreater(large[0], normal[0])
        self.assertGreater(large[1], normal[1])
        # Text smaller than normal never shrinks below the base size.
        self.assertEqual(sizing.default_window_size(0.8, None), normal)
        # Only real screens limit the window: a tiny nested output is ignored.
        self.assertEqual(sizing.smallest_usable_monitor([(342, 171), (3440, 1440), (1920, 1080)]),
                         (1920, 1080))
        # Without any real screen there is no limit at all.
        self.assertIsNone(sizing.smallest_usable_monitor([(342, 171)]))
        capped = sizing.default_window_size(1.64, (1280, 720))
        self.assertLessEqual(capped[0], 1280 * 0.9)
        self.assertLessEqual(capped[1], 720 * 0.9)


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

    def test_scroll_direction_has_the_requested_labels(self):
        """The manager asked for these exact human labels."""
        self.assertEqual(presentation.option_label("BIND_SCROLL_DIRECTION", "down-in"),
                         "Scroll down zooms in")
        self.assertEqual(presentation.option_label("BIND_SCROLL_DIRECTION", "up-in"),
                         "Scroll up zooms in")

    def test_every_choice_list_has_a_question_and_units_are_declared(self):
        """Lists need a heading that is not the page title; ms settings convert."""
        for key in presentation.CHOICE_LIST_KEYS:
            self.assertIn(key, presentation.CHOICE_QUESTIONS)
        # Units are converted where people think in other units.
        unit = presentation.display_unit("ZOOM_ANIMATION_SPEED")
        self.assertEqual((unit.suffix, unit.factor), ("ms", 100.0))
        self.assertIsNone(presentation.display_unit("ZOOM_STEP"))

    def test_us_english_everywhere(self):
        """E13: no British spellings in titles and option texts."""
        texts = [info.title + info.description for info in presentation.GROUPS]
        for options in presentation.OPTION_TEXT.values():
            # Every option label and explanation is checked.
            texts += [label + text for label, text in options.values()]
        for word in ("colour", "Colour", "Centred", "recognis", "Behaviour"):
            self.assertFalse([t for t in texts if word in t], word)

    def test_every_schema_enum_option_has_hand_written_text(self):
        """New schema options without presentation text must be noticed here."""
        for spec in real_schema().specs:
            for option in spec.choices:
                self.assertIsNotNone(
                    presentation.option_description(spec.key, option), f"{spec.key}={option}"
                )


# Allows running this file directly.
if __name__ == "__main__":
    unittest.main()
