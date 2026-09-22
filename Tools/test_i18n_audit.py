"""Tests for Tools/i18n_audit.py, the Apple String Catalog coverage audit.

Run: python3 -m unittest Tools.test_i18n_audit -v   (from the repo root)
     or: cd Tools && python3 -m unittest test_i18n_audit -v
"""

import json
import tempfile
import unittest
from pathlib import Path

import i18n_audit as ia


class FormatSpecExclusion(unittest.TestCase):
    def test_pure_format_spec_excluded(self):
        self.assertFalse(ia.is_probably_ui_text("%.1f"))
        self.assertFalse(ia.is_probably_ui_text("%02d"))
        self.assertFalse(ia.is_probably_ui_text("%+.2f"))

    def test_format_spec_with_real_text_kept(self):
        self.assertTrue(ia.is_probably_ui_text("%.1f br/min"))


class Baseline(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self._orig_path = ia.BASELINE_PATH
        ia.BASELINE_PATH = Path(self.tmp.name) / "baseline.json"
        self.addCleanup(setattr, ia, "BASELINE_PATH", self._orig_path)

    def test_missing_baseline_is_empty(self):
        self.assertEqual(ia.load_baseline(), {"ios": set()})

    def test_round_trip(self):
        ia.BASELINE_PATH.write_text(
            json.dumps({"ios": [["Strand/Screens/A.swift", "Old"]]}), encoding="utf-8"
        )
        self.assertEqual(ia.load_baseline(), {"ios": {("Strand/Screens/A.swift", "Old")}})

    def test_baseline_keyed_by_path_and_literal_not_line(self):
        # A baseline entry must keep suppressing a finding whose line number
        # shifted from an unrelated edit elsewhere in the same file.
        ia.BASELINE_PATH.write_text(
            json.dumps({"ios": [["Strand/Screens/A.swift", "Save"]]}), encoding="utf-8"
        )
        baseline = ia.load_baseline()
        finding = ("Strand/Screens/A.swift", 999, "Save")  # line number drifted
        self.assertIn((finding[0], finding[2]), baseline["ios"])

    def test_unknown_top_level_keys_are_ignored(self):
        # An older baseline file may still carry keys this audit no longer
        # tracks; loading one must neither crash nor leak them into the result.
        ia.BASELINE_PATH.write_text(
            json.dumps({"legacy": [["Legacy/Screen.txt", "Old"]], "ios": []}), encoding="utf-8"
        )
        self.assertEqual(ia.load_baseline(), {"ios": set()})


class EchoDetectionWordFilter(unittest.TestCase):
    """`_has_translatable_words` is the false-positive guard for the echo gate: it decides whether a
    string identical across languages is a suspicious untranslated ECHO or a legitimately-identical
    term. It backs the echo count (a `translated` unit whose value is still the source key)."""

    def test_real_phrase_is_translatable(self):
        self.assertTrue(ia._has_translatable_words("Add a daily action"))
        self.assertTrue(ia._has_translatable_words("Predictive runtime warning"))

    def test_format_only_string_is_not(self):
        # Placeholders + punctuation with nothing to translate — a locale repeating them is CORRECT.
        self.assertFalse(ia._has_translatable_words("%@ · %lld"))
        self.assertFalse(ia._has_translatable_words("%1$s: %2$s. %3$s"))

    def test_single_word_term_is_not(self):
        # One word is very often a term of art / brand that legitimately travels.
        self.assertFalse(ia._has_translatable_words("HRV"))
        self.assertFalse(ia._has_translatable_words("Yoga"))

    def test_symbols_and_punctuation_are_not(self):
        self.assertFalse(ia._has_translatable_words("· • —"))

    def test_positional_specifiers_are_stripped(self):
        # "vs prev %1$s" keeps the words "vs"/"prev" — a Spanish copy repeating it verbatim is an echo.
        self.assertTrue(ia._has_translatable_words("vs prev %1$s"))
        # "%1$d%%" is pure format + literal percent — nothing to translate.
        self.assertFalse(ia._has_translatable_words("%1$d%%"))

    def test_two_word_brand_is_flagged(self):
        # Deliberately True: "Apple Health" IS caught, and the ratchet baseline absorbs it as an allowed
        # legitimate echo — the gate's job is to block GROWTH, not to pre-judge every identical string.
        self.assertTrue(ia._has_translatable_words("Apple Health"))



class CatalogSummaryPluralCoverage(unittest.TestCase):
    """The human-readable coverage summary must count plural entries the same way the gate does.

    `catalog_summary` used to read `localizations[lang].stringUnit.state` directly. A pluralised entry
    keeps its units under `variations.plural.<category>.stringUnit`, so that flat lookup returned None
    and scored a fully-translated plural as a gap — it reported de/es/fr/pt-PT missing=4 and pl missing=5
    on the Strand catalog when every one of those was translated in every form, and it made Polish look
    worst-covered precisely because it correctly carries one/few/many/other.
    """

    def _summary(self, catalog: dict) -> str:
        import contextlib
        import io
        saved_catalogs, saved_load = ia.CATALOGS, ia.load_catalog
        try:
            ia.CATALOGS = [((), ia.ROOT / "fixture" / "Localizable.xcstrings")]
            ia.load_catalog = lambda _path: catalog
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                ia.catalog_summary()
            return buf.getvalue()
        finally:
            ia.CATALOGS, ia.load_catalog = saved_catalogs, saved_load

    @staticmethod
    def _plural(states: dict[str, str]) -> dict:
        return {"variations": {"plural": {
            cat: {"stringUnit": {"state": st, "value": f"{cat} form"}} for cat, st in states.items()
        }}}

    def test_fully_translated_plural_is_not_a_gap(self):
        cat = {"strings": {"%lld days": {"localizations": {
            lang: self._plural({"one": "translated", "other": "translated"})
            for lang in ("de", "es", "fr", "pt-PT")
        }}}}
        out = self._summary(cat)
        for lang in ("de", "es", "fr", "pt-PT"):
            self.assertIn(f"{lang} missing=0", out)

    def test_polish_extra_plural_categories_are_not_penalised(self):
        """one/few/many/other is Polish being handled correctly, not five gaps."""
        cat = {"strings": {"%lld days": {"localizations": {
            "pl": self._plural({c: "translated" for c in ("one", "few", "many", "other")}),
        }}}}
        self.assertIn("pl missing=0", self._summary(cat))

    def test_partially_translated_plural_is_still_a_gap(self):
        """The fix must not over-correct: one untranslated category still counts."""
        cat = {"strings": {"%lld days": {"localizations": {
            "de": self._plural({"one": "translated", "other": "new"}),
        }}}}
        self.assertIn("de missing=1", self._summary(cat))

    def test_flat_string_unit_still_counted(self):
        """Non-plural entries keep working exactly as before."""
        cat = {"strings": {
            "Hello": {"localizations": {"de": {"stringUnit": {"state": "translated", "value": "Hallo"}}}},
            "Bye": {"localizations": {"de": {"stringUnit": {"state": "new", "value": ""}}}},
        }}
        self.assertIn("de missing=1", self._summary(cat))

    def test_should_translate_false_is_skipped(self):
        cat = {"strings": {"NOOP": {"shouldTranslate": False, "localizations": {}}}}
        self.assertIn("de missing=0", self._summary(cat))


class SwiftReturnedCopyTests(unittest.TestCase):
    """Copy a screen RETURNS as a String, not copy sitting inside a `Text(...)` argument.

    The scanner used to look only inside localized SwiftUI calls, so a literal returned from a
    `var label: String { ... }` was invisible. That is not a harmless miss: a bare literal returned that
    way reaches `Text` already resolved and renders in English on every device forever. It shipped once
    that way, a Workouts Current/Archived tab pair, while the gate passed, having flagged only the
    accessibility key beside it.
    """

    def found(self, text: str) -> list[str]:
        return [lit for _, lit in ia.swift_returned_copy_literals(text)]

    def test_ternary_form_is_seen(self):
        src = 'var label: String { self == .a ? "Alpha" : "Beta" }'
        self.assertEqual(self.found(src), ["Alpha", "Beta"])

    def test_switch_arm_is_seen(self):
        # The shape this rule MUST cover, and the one its first draft missed: a `switch` opens a second
        # brace level, so keying on brace depth silently skipped every case arm while the ternary above
        # still passed. Switch is the commoner spelling in this repository.
        src = (
            'var label: String {\n'
            '    switch self {\n'
            '    case .a: return "Alpha"\n'
            '    case .b: return "Beta"\n'
            '    }\n'
            '}'
        )
        self.assertEqual(self.found(src), ["Alpha", "Beta"])

    def test_implicit_return_switch_arm_is_seen(self):
        src = 'var title: String {\n    switch self {\n    case .a: "Alpha"\n    }\n}'
        self.assertEqual(self.found(src), ["Alpha"])

    def test_string_localized_is_left_to_the_normal_scan(self):
        # The sanctioned spelling for a value that has to be a String. Flagging it would punish the
        # convention this rule exists to protect.
        src = 'var label: String {\n    switch self {\n    case .a: return String(localized: "Alpha")\n    }\n}'
        self.assertEqual(self.found(src), [])

    def test_argument_labels_are_not_mistaken_for_case_arms(self):
        # `joined(separator: ", ")` ends in a colon exactly like `case .a:`, so a bare "ends with a
        # colon" test reported the separator as untranslated UI.
        src = 'var label: String {\n    let p = names.joined(separator: ", ")\n    return p\n}'
        self.assertEqual(self.found(src), [])

    def test_non_copy_property_names_are_ignored(self):
        # Only names that ARE copy. A `var id: String` or a `var sportKey: String` returns an
        # identifier, and sweeping those is what produced 71 findings in the first draft.
        for src in (
            'var id: String { "raw-token" }',
            'var sportKey: String { return "running" }',
        ):
            self.assertEqual(self.found(src), [], src)

    def test_nested_closure_literal_is_not_returned_copy(self):
        src = (
            'var label: String {\n'
            '    let joined = items.map { $0.replacingOccurrences(of: "x", with: "y") }\n'
            '    return joined.first ?? ""\n'
            '}'
        )
        self.assertNotIn("x", self.found(src))


class SwiftLocalizedStringScanning(unittest.TestCase):
    """`String(localized:)` copy must reach the catalog-membership check.

    The scanner keys off SWIFT_CALL_START_PATTERN, which listed the SwiftUI views and modifiers that
    localize but not `String(localized:)`. So the sanctioned spelling for copy that has to be a `String`
    was the one spelling nothing checked a key for. `swift_returned_copy_literals` deliberately skips it
    and said so in a comment, delegating to "the normal scan" that in fact never looked, which is how the
    hole stayed invisible: 242 such strings resolve to no catalog entry and render English in every
    locale, the app's legal terms in `Strand/App/Terms.swift` among them.
    """

    def found(self, text: str) -> list[str]:
        return [lit for _, lit in ia.swift_string_literals(text)]

    def test_localized_string_is_seen(self):
        self.assertEqual(self.found('let x = String(localized: "Alpha")'), ["Alpha"])

    def test_interpolated_localized_string_is_seen(self):
        # The shape that shipped unlocalized: a tooltip built as `String(localized: "1m \(v)")`.
        self.assertEqual(self.found('let x = String(localized: "1m \\(v)")'), ["1m \\(v)"])

    def test_string_format_is_not_copy(self):
        # `String(format:)` carries a format spec, not user-facing copy.
        self.assertEqual(self.found('let x = String(format: "%.1f", v)'), [])

    def test_string_describing_is_not_copy(self):
        self.assertEqual(self.found('let x = String(describing: "raw")'), [])

    def test_spacing_variants_are_seen(self):
        self.assertEqual(self.found('let x = String( localized: "Alpha")'), ["Alpha"])

    def test_localized_alongside_a_view_literal(self):
        src = 'Text("Shown")\nlet x = String(localized: "Also shown")'
        self.assertEqual(self.found(src), ["Shown", "Also shown"])


if __name__ == "__main__":
    unittest.main()
