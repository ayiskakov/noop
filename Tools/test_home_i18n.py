#!/usr/bin/env python3
"""Focused zero-baseline localization guard for the phone Home/Today surfaces.

This intentionally does not use the repository-wide grandfathered baseline.  Once the
Home migration is complete, every finding in this source closure must stay at zero.
Run with::

    python3 Tools/test_home_i18n.py
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

import i18n_audit as audit


ROOT = Path(__file__).resolve().parents[1]

# Both selectable Today implementations, their Today-only editor/metadata, the shared
# day picker that they render, and the iPhone shell/icon actions that enter Home.
APPLE_HOME_FILES = {
    "Strand/Screens/TodayView.swift",
    "Strand/Liquid/LiquidTodayView.swift",
    "Strand/Screens/TodayCustomizationSheet.swift",
    "Strand/Screens/TodayCustomizationMetadata.swift",
    "Packages/StrandDesign/Sources/StrandDesign/DayNavBar.swift",
    "StrandiOS/System/HomeScreenQuickActions.swift",
    "Strand/Screens/AutoWorkoutCard.swift",
    "Strand/Screens/JournalReminderCard.swift",
    "Strand/Screens/SkinTempCardsView.swift",
    "Strand/Screens/HealthAlertBanner.swift",
}
APPLE_SHELL_FILE = "StrandiOS/App/RootTabView.swift"

# RootTabView also owns the unrelated More tab.  Limit its Home contract to the
# Today tab label, the sheet opened from Today's + button, and that sheet's close
# affordance instead of treating every future RootTabView string as Home copy.
APPLE_HOME_SHELL_CATALOG_KEYS = {
    "Today", "Done", "QUICK ACTIONS", "Live HR", "Start workout", "Log journal", "Breathe",
}

SWIFT_LOCALIZED_CALL = re.compile(r"\b(?:String\s*\(\s*localized:|LocalizedStringKey\s*\()\s*\"")


def _format_findings(rows: list[tuple[str, int, str]]) -> str:
    return "\n".join(f"{path}:{line}: {literal!r}" for path, line, literal in rows)


def _apple_catalog_for(path: str) -> Path:
    if path.startswith("Packages/StrandDesign/"):
        return ROOT / "Packages/StrandDesign/Sources/StrandDesign/Resources/Localizable.xcstrings"
    return ROOT / "Strand/Resources/Localizable.xcstrings"


def _localized_swift_literals(path: Path) -> set[str]:
    """Catalog-backed literals used by SwiftUI or explicit String(localized:)."""
    text = path.read_text(encoding="utf-8")
    literals = {literal for _, literal in audit.swift_string_literals(text)}
    for match in SWIFT_LOCALIZED_CALL.finditer(text):
        quote = match.end() - 1
        end = audit._skip_swift_string_literal(text, quote)
        literals.add(text[quote + 1:end - 1])
    return {literal for literal in literals if audit.is_probably_ui_text(literal)}


class HomeLocalizationTest(unittest.TestCase):
    maxDiff = None

    def test_apple_home_has_no_audit_findings(self) -> None:
        findings, _ = audit.scan_ios()
        scoped = [row for row in findings if row[0] in APPLE_HOME_FILES]
        self.assertEqual([], scoped, "Unlocalized Apple Home UI:\n" + _format_findings(scoped))

    def test_apple_day_nav_dynamic_date_avoids_multiline_interpolation(self) -> None:
        source = (ROOT / "Packages/StrandDesign/Sources/StrandDesign/DayNavBar.swift").read_text(encoding="utf-8")
        self.assertIn("let formattedDay = selectedDay.formatted(", source)
        self.assertIn("return LocalizedStringKey(formattedDay)", source)
        self.assertNotIn('return "\\(selectedDay.formatted(', source)

    def test_apple_charge_driver_verdicts_are_complete_catalog_keys(self) -> None:
        source = (ROOT / "Packages/StrandAnalytics/Sources/StrandAnalytics/ChargeDrivers.swift").read_text(
            encoding="utf-8"
        )
        verdict_block = source.split("// MARK: - Plain-English verdicts", 1)[1].split(
            "static func skinTempDevText", 1
        )[0]
        verdicts = set(re.findall(r'(?:return|\?|:)\s*"([^"]+)"', verdict_block))
        # Thirteen return paths currently collapse to twelve unique keys because several helpers share
        # "at baseline". Pin the unique-key set size so syntax changes cannot silently evade extraction.
        self.assertEqual(12, len(verdicts), "Verdict extraction changed; review the catalog contract")

        catalog = audit.load_catalog(ROOT / "Strand/Resources/Localizable.xcstrings")
        missing = []
        for verdict in sorted(verdicts):
            entry = audit.swift_catalog_lookup(catalog, verdict)
            if entry is None:
                missing.append(f"all: {verdict!r} absent from catalog")
                continue
            for lang in audit.LANGS:
                if not audit._is_translated(entry, lang):
                    missing.append(f"{lang}: {verdict!r}")
        self.assertEqual([], missing, "Missing Charge-driver verdict translations:\n" + "\n".join(missing))

    def test_apple_home_catalog_entries_cover_focus_locales(self) -> None:
        missing: list[str] = []
        catalogs: dict[Path, dict] = {}
        for relative in sorted(APPLE_HOME_FILES):
            catalog_path = _apple_catalog_for(relative)
            catalog = catalogs.setdefault(catalog_path, audit.load_catalog(catalog_path))
            for literal in sorted(_localized_swift_literals(ROOT / relative)):
                entry = audit.swift_catalog_lookup(catalog, literal)
                if entry is None:
                    # The source-finding test reports this with a useful line number.
                    continue
                for lang in audit.LANGS:
                    if not audit._is_translated(entry, lang):
                        missing.append(f"{relative}: {lang}: {literal!r}")

        shell_catalog_path = _apple_catalog_for(APPLE_SHELL_FILE)
        shell_catalog = catalogs.setdefault(shell_catalog_path, audit.load_catalog(shell_catalog_path))
        for literal in sorted(APPLE_HOME_SHELL_CATALOG_KEYS):
            entry = audit.swift_catalog_lookup(shell_catalog, literal)
            if entry is None:
                missing.append(f"{APPLE_SHELL_FILE}: all: {literal!r} absent from catalog")
                continue
            for lang in audit.LANGS:
                if not audit._is_translated(entry, lang):
                    missing.append(f"{APPLE_SHELL_FILE}: {lang}: {literal!r}")
        self.assertEqual([], missing, "Missing Apple Home catalog translations:\n" + "\n".join(missing))

    def test_apple_skin_temp_dynamic_copy_uses_swift_interpolation(self) -> None:
        source = (ROOT / "Strand/Screens/SkinTempCardsView.swift").read_text(encoding="utf-8")
        for argument in ("hours", "signals", "reasons"):
            self.assertIn(
                rf"\({argument})",
                source,
                f"Skin-temperature localized copy must interpolate {argument} with Swift syntax",
            )

    def test_apple_whoop_brand_and_tint_are_locale_independent(self) -> None:
        source = (ROOT / "Strand/Screens/TodayView.swift").read_text(encoding="utf-8")
        catalog = audit.load_catalog(ROOT / "Strand/Resources/Localizable.xcstrings")
        self.assertEqual("WHOOP", catalog["strings"]["Whoop"]["localizations"]["pt-PT"]["stringUnit"]["value"])
        self.assertIn('private static let whoopBrandName = "WHOOP"', source)

        tint_start = source.index("private func provenanceTint")
        tint_end = source.index("// MARK: Apple Watch provenance", tint_start)
        self.assertNotIn("provenanceLabel(", source[tint_start:tint_end])

    def test_apple_liquid_runtime_copy_and_pt_terms_are_localized(self) -> None:
        source = (ROOT / "Strand/Liquid/LiquidTodayView.swift").read_text(encoding="utf-8")
        self.assertIn(
            'private var stressText: String { stress.map { String(Int($0.rounded())) } ?? String(localized: "Calibrating") }',
            source,
        )
        self.assertIn('return "\\(base) · \\(String(localized: \"Charging\"))"', source)

        strings = audit.load_catalog(ROOT / "Strand/Resources/Localizable.xcstrings")["strings"]
        expected = {
            "Push": "Avançar",
            "SYNTHESIS": "SÍNTESE",
            "Still": "Parado",
        }
        for key, value in expected.items():
            self.assertEqual(value, strings[key]["localizations"]["pt-PT"]["stringUnit"]["value"])

    def test_apple_home_semantic_display_contracts(self) -> None:
        app_model = (ROOT / "Strand/App/AppModel.swift").read_text(encoding="utf-8")
        illness = (ROOT / "Packages/StrandAnalytics/Sources/StrandAnalytics/IllnessSignalEngine.swift").read_text(encoding="utf-8")
        readiness = (ROOT / "Packages/StrandAnalytics/Sources/StrandAnalytics/ReadinessEngine.swift").read_text(encoding="utf-8")
        today = (ROOT / "Strand/Screens/TodayView.swift").read_text(encoding="utf-8")

        self.assertIn("public enum Message", illness)
        self.assertIn('suppressedBy.append("a hard or late workout")', illness)
        self.assertIn("suppressionReasons.append(.hardOrLateWorkout)", illness)
        self.assertNotIn('result.copy.contains("numbers agree")', (ROOT / "Strand/Screens/SkinTempCardsView.swift").read_text(encoding="utf-8"))
        self.assertIn('String(localized: "RHR +\\(delta)")', app_model)
        self.assertIn('String(localized: "HRV −\\(percent)%")', app_model)
        # 240c48ae (#1671): the label now carries the reader's unit via UnitFormatter.skinTempSignalPhrase,
        # so the sign and the hardcoded °C moved out of the localized literal.
        self.assertIn('String(localized: "Skin temperature \\(temperature)")', app_model)
        self.assertIn('String(localized: "Respiration up")', app_model)

        self.assertIn("public enum Evidence", readiness)
        self.assertIn("readinessEvidenceText", today)
        self.assertIn("readinessDetailText", today)
        self.assertIn('String(format: "%.\\(decimals)f", locale: AppLanguage.activeLocale, value)', today)
        self.assertNotIn("if let evidence = s.evidence", today)
        self.assertNotIn("LocalizedStringKey(s.detail)", today)

        self.assertIn("badge: Self.whoopBrandName", today)
        self.assertIn('case .nutritionCsv: return String(localized: "Nutrition")', today)
        self.assertIn('case .localCache: return String(localized: "Cached")', today)

        strings = audit.load_catalog(ROOT / "Strand/Resources/Localizable.xcstrings")["strings"]
        for key in (
            "RHR +%lld", "HRV −%lld%%", "Skin temperature %@", "Respiration up",
            "%@ vs %@ %@", "7d %@ / 28d %@", "monotony %@",
        ):
            self.assertIn(key, strings)
            for lang in audit.LANGS:
                self.assertTrue(audit._is_translated(strings[key], lang), f"{lang}: {key}")

    def test_apple_pt_home_terms_are_context_correct(self) -> None:
        strings = audit.load_catalog(ROOT / "Strand/Resources/Localizable.xcstrings")["strings"]
        expected = {
            "Strap battery": "Bateria da pulseira",
            "Needs the strap": "Requer a pulseira",
            "Run down": "Esgotado",
            "Rest HR": "FC repouso",
            "Resting HR": "FC em repouso",
            "Your cards": "Os teus cartões",
            "~%lldh left": "Faltam ~%lld h",
            "%lld days · %lld sleeps": "%1$lld dias · %2$lld noites de sono",
        }
        for key, value in expected.items():
            self.assertEqual(value, strings[key]["localizations"]["pt-PT"]["stringUnit"]["value"])

    def test_apple_home_banner_and_suppression_contract_are_semantic(self) -> None:
        app_model = (ROOT / "Strand/App/AppModel.swift").read_text(encoding="utf-8")
        banner = (ROOT / "Strand/Screens/HealthAlertBanner.swift").read_text(encoding="utf-8")
        illness = (ROOT / "Packages/StrandAnalytics/Sources/StrandAnalytics/IllnessSignalEngine.swift").read_text(encoding="utf-8")

        self.assertIn("struct HealthAlert: Equatable", app_model)
        self.assertIn("let message: IllnessSignalEngine.Message", app_model)
        self.assertIn("@Published var healthAlert: HealthAlert?", app_model)
        self.assertNotIn("? result.copy : nil", app_model)
        self.assertIn("localizedHealthAlertCopy", banner)
        self.assertNotIn("Text(alert)", banner)
        self.assertIn('suppressedBy.append("a hard or late workout")', illness)
        self.assertIn("public enum SuppressionReason", illness)
        self.assertIn("public let suppressionReasons: [SuppressionReason]", illness)

    def test_apple_de_score_glossary_preserves_physiology_terms(self) -> None:
        strings = audit.load_catalog(ROOT / "Strand/Resources/Localizable.xcstrings")["strings"]
        values = [
            entry.get("localizations", {}).get("de", {}).get("stringUnit", {}).get("value", "")
            for entry in strings.values()
        ]
        joined = "\n".join(values)
        self.assertNotIn("Erholungherz", joined)
        self.assertNotIn("Erholungqualität", joined)
        self.assertNotIn("Erholung- und Live-Herzfrequenz", joined)
        for key, expected in {
            "Charge": "Energie",
            "Effort": "Belastung",
            "Rest": "Erholung",
            "How Rest is calculated": "So wird Erholung berechnet",
        }.items():
            self.assertEqual(expected, strings[key]["localizations"]["de"]["stringUnit"]["value"])

    def test_apple_home_count_catalogs_have_real_focus_plural_variations(self) -> None:
        today = (ROOT / "Strand/Screens/TodayView.swift").read_text(encoding="utf-8")
        strings = audit.load_catalog(ROOT / "Strand/Resources/Localizable.xcstrings")["strings"]
        self.assertNotIn('String(localized: "\\(repo.days.count) days · \\(repo.sleeps.count) sleeps")', today)
        self.assertIn("localizedDayCount", today)
        self.assertIn("localizedSleepCount", today)
        self.assertIn("localizedWorkoutCount", today)
        for key in ("%lld days", "%lld sleeps", "%lld workouts"):
            for lang in ("en", *audit.LANGS, "it"):
                localization = strings[key].get("localizations", {}).get(lang, {})
                plural = localization.get("variations", {}).get("plural", {})
                self.assertIn("one", plural, f"{lang}: {key} missing singular")
                self.assertIn("other", plural, f"{lang}: {key} missing plural")

    def test_apple_illness_messages_are_not_portuguese_in_other_locales(self) -> None:
        strings = audit.load_catalog(ROOT / "Strand/Resources/Localizable.xcstrings")["strings"]
        keys = (
            "Your body looks strained. Signals up: %@. No alcohol or travel was logged, so consider taking it easy. On-device estimate, not a diagnosis.",
            "You logged feeling unwell, and your signals agree. Take it easy today. On-device estimate, not a diagnosis.",
            "You logged feeling unwell. Take it easy today. On-device estimate, not a diagnosis.",
            "Some signals are up, but you logged %@. That is the more likely explanation. On-device estimate, not a diagnosis.",
            "A few signals are mildly up: %@. Nothing alarming, but a calmer day may help. On-device estimate, not a diagnosis.",
            "Still learning your baseline and keeping an eye on your signals.",
            "Nothing notable. Your signals look like their normal range.",
        )
        for key in keys:
            localizations = strings[key]["localizations"]
            pt = localizations["pt-PT"]["stringUnit"]["value"]
            for lang in ("it", "pl", "ru", "zh-Hans", "zh-Hant"):
                self.assertNotEqual(pt, localizations[lang]["stringUnit"]["value"], f"{lang}: {key}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
