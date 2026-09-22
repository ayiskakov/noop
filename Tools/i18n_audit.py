#!/usr/bin/env python3
"""Audit user-facing text in the Apple app targets for translation gaps.

Two independent problems, both covered here:

1. Un-extracted literals — a `Text("Charge")`-style literal that resolves to
   no entry in its target String Catalog, so it renders in English on every
   device. Reported as HARDCODED.
2. Catalog drift — a string IS in the String Catalog (a SwiftUI
   LocalizedStringKey or `String(localized:)`) but a target language's
   translation is missing or still marked `new`. Reported as MISSING_<LANG>.

Target languages: de, es, fr, pt-PT (the focus set). English is the source
language and is not checked for itself. Every other locale a catalog ships is
gated against a ratcheting allowance (see `extra_locale_allowance`).

Read-only. Prints a report; does not modify any file (except with
`--update-baseline`). The same logic backs the CI gate in i18n-coverage.yml.

Usage: python3 Tools/i18n_audit.py [--full] [--ci BASE_REF] [--update-baseline]
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Callable

ROOT = Path(__file__).resolve().parent.parent
LANGS = ["de", "es", "fr", "pt-PT"]

# A file's text (or None if absent) at some point in time — either the
# working tree (`_disk_read`) or a git ref (`ref_reader`). Every scan_*/
# *_gaps function accepts one so `ci_check` can compute the same violations
# at HEAD and at `base_ref` and diff the two.
Reader = Callable[[Path], str | None]

# Strings that are legitimately identical across all languages (symbols,
# format-only placeholders, brand name, units) — mirrors the exclude
# reasoning already established in Tools/translate-de.py. Extend as needed;
# false positives here just mean noise in the report, not a wrong fix.
UNIVERSAL = {
    "", "-", "–", "—", "·", "•", "✓", "→", "↔",
    "NOOP", "bpm", "BPM", "HRV", "SpO2", "SpO₂", "OK", "ID",
    # Training-load acronyms — universal training-science terms, identical in every language (like HRV).
    "CTL", "ATL", "TSB",
}

# A bare printf/String.format conversion specifier, e.g. "%.1f" or "%02d" — a
# format string, not translatable copy. `re.search(r"[A-Za-z]", s)` alone
# can't tell these apart from real text, since the conversion character
# itself (f/d/s/...) counts as a letter.
PURE_FORMAT_SPEC = re.compile(r"^%[-+0 #,(]*\d*(?:\.\d+)?[sdifoxXeEgGcC]$")


def is_probably_ui_text(s: str) -> bool:
    """Filter out obvious non-UI-text matches (identifiers, tags, formats)."""
    if s in UNIVERSAL:
        return False
    if not re.search(r"[A-Za-z]", s):
        return False  # pure symbols/numbers/format specifiers
    if PURE_FORMAT_SPEC.fullmatch(s):
        return False
    # snake_case / dotted / slashed identifiers (testTags, routes, keys) —
    # real UI copy almost always has a space or is a capitalized single word.
    if re.fullmatch(r"[a-z][a-z0-9_./]*", s) and " " not in s:
        return False
    if s.startswith("http://") or s.startswith("https://"):
        return False
    return True



# ---------------------------------------------------------------------------
# Apple: catalog drift + un-extracted literals
# ---------------------------------------------------------------------------

CATALOGS = [
    (
        [ROOT / "Packages/StrandDesign/Sources/StrandDesign"],
        ROOT / "Packages/StrandDesign/Sources/StrandDesign/Resources/Localizable.xcstrings",
    ),
    (
        [ROOT / "NOOPWatch"],
        ROOT / "NOOPWatch/Localizable.xcstrings",
    ),
    (
        [ROOT / "NOOPWatchComplications"],
        ROOT / "NOOPWatchComplications/Localizable.xcstrings",
    ),
    (
        [ROOT / "Strand", ROOT / "StrandiOS", ROOT / "StrandiOSShared", ROOT / "StrandiOSWidgets"],
        ROOT / "Strand/Resources/Localizable.xcstrings",
    ),
]

SWIFT_CALL_START_PATTERN = re.compile(
    r"\b(?:Text|Button|Label|Toggle|Menu|Picker|ProgressView|SectionHeader)\s*\("
    r"|"
    r"\.(?:navigationTitle|confirmationDialog|alert|accessibilityLabel|help)\s*\("
    r"|"
    # `String(localized:)` is the sanctioned spelling for copy that has to be a `String`, and it
    # still has to EXIST in the catalog to render in anything but English. Without this alternative
    # the spelling was invisible here, so nothing checked its key: 242 of them resolve to no catalog
    # entry and ship English in every locale, the app's legal terms among them. The lookahead keeps
    # `String(format:)`/`String(describing:)` out, which are not copy.
    r"\bString\s*\((?=\s*localized:)"
)

# A computed property that RETURNS user-facing copy as a `String`, e.g.
# `var label: String { ... }` on a screen's scope/mode enum.
#
# These are invisible to SWIFT_CALL_START_PATTERN above, because the literal sits
# in a `return`, not inside a `Text(`/`Picker(` argument. That is not a harmless
# miss: a bare literal returned as a String reaches `Text` already resolved, so it
# renders in English on every device forever, and nothing flags it. It shipped
# exactly once that way (a Workouts "Current"/"Archived" tab pair) while the gate
# passed, having caught only the accessibility label beside it.
#
# The repository's own convention already avoids this, either `String(localized:)`
# for a value that must be a String, or `LocalizedStringKey` when the value only
# ever reaches `Text`. Both are recognised: the first because the literal sits in
# a `localized:` argument, the second because `LocalizedStringKey` resolves in the
# view environment. So this rule has no pre-existing findings to baseline; it
# exists to keep it that way.
#
# Deliberately narrow. It matches only property names that ARE copy (label, title,
# caption, subtitle) and only literals that are returned, so the many String
# helpers that build keys, symbol names, trace tokens and log lines stay out.
SWIFT_COPY_PROPERTY_PATTERN = re.compile(
    r"\bvar\s+\w*(?:label|title|caption|subtitle)\w*\s*:\s*String\s*\{",
    re.IGNORECASE,
)

# A placeholder generated by Swift's LocalizedStringKey interpolation. The
# precise conversion depends on the interpolated value's static type, so the
# source-side audit deliberately accepts any valid String Catalog placeholder
# at that position instead of trying to reproduce compiler type inference.
CATALOG_PLACEHOLDER_PATTERN = r"%(?:(?:\d+)\$)?(?:@|[-+0 #']*(?:\d+|\*)?(?:\.\d+|\.\*)?(?:hh|h|ll|l|q|z|t|j)?[diuoxXfFeEgGaAcCsSp])"


def _skip_swift_string_literal(text: str, i: int) -> int:
    """`text[i]` is the opening `"` of a Swift string literal; return the
    index just past its closing `"`, honoring backslash escapes AND
    `\\(expr)` interpolation, which can itself contain a nested string
    literal (`Text("\\(String(format: "%.1f", value)) bpm")`) — a naive scan
    for the next `"` would end the OUTER literal early on that one."""
    i += 1
    while i < len(text):
        ch = text[i]
        if ch == "\\" and i + 1 < len(text):
            if text[i + 1] == "(":
                i += 2
                depth = 1
                while i < len(text) and depth:
                    c2 = text[i]
                    if c2 == '"':
                        i = _skip_swift_string_literal(text, i)
                        continue
                    if c2 == "(":
                        depth += 1
                    elif c2 == ")":
                        depth -= 1
                    i += 1
                continue
            i += 2
            continue
        if ch == '"':
            return i + 1
        i += 1
    return i


def _swift_argument_span_end(text: str, start: int) -> int:
    """`start` is just after a call's `(`; return the index where its first
    argument's expression ends — the next top-level comma, or the bracket
    that closes the call."""
    depth = 0
    i = start
    while i < len(text):
        ch = text[i]
        if ch == '"':
            i = _skip_swift_string_literal(text, i)
            continue
        if ch in "({[":
            depth += 1
        elif ch in ")}]":
            if depth == 0:
                return i
            depth -= 1
        elif ch == "," and depth == 0:
            return i
        i += 1
    return i


def swift_string_literals(text: str):
    """Yield (offset, literal contents) for every literal directly reachable
    in a localized SwiftUI call's FIRST argument — descends transparently
    through `(`/`[` (so `cond ? "a" : "b"` and nested calls are visible) but
    skips any `{...}` untouched (a SwiftUI trailing closure, e.g.
    `Button(action: { ... }) { Text("...") }`'s `action:` closure — not text,
    and whatever real text a trailing closure DOES carry, like that
    example's `Text("...")`, is found independently when the file-wide scan
    reaches it directly). Previously required the literal immediately after
    the call's `(`, so `Text(cond ? "Off" : "On")` was invisible — not just
    to this audit, but functionally: that ternary resolves to SwiftUI's
    non-localizing `Text<S: StringProtocol>` overload, so it was always
    English regardless of device language (#540).
    """
    for match in SWIFT_CALL_START_PATTERN.finditer(text):
        open_paren = match.end() - 1
        end = _swift_argument_span_end(text, open_paren + 1)
        i = open_paren + 1
        while i < end:
            ch = text[i]
            if ch == '"':
                j = _skip_swift_string_literal(text, i)
                yield i, text[i + 1:j - 1]
                i = j
                continue
            if ch == "{":
                depth = 1
                i += 1
                while i < end and depth:
                    c2 = text[i]
                    if c2 == '"':
                        i = _skip_swift_string_literal(text, i)
                        continue
                    if c2 in "({[":
                        depth += 1
                    elif c2 in ")}]":
                        depth -= 1
                    i += 1
                continue
            i += 1


def swift_returned_copy_literals(text: str):
    """Yield (offset, literal) for copy RETURNED as a String from a `var label: String { ... }`-shaped
    property, e.g. `case .current: return "Current"`.

    Separate from `swift_string_literals`, and applied to SCREEN files only, because the same shape means
    something else elsewhere: `Commands.swift` names BLE opcodes through a `var label: String`, and those
    are diagnostics rather than copy a wearer reads. That directory restriction is what keeps this rule at
    zero pre-existing findings instead of 71.

    Only literals at the property's own brace level are yielded, so one nested inside a closure or a
    helper call stays out and string building is not flagged.
    """
    for match in SWIFT_COPY_PROPERTY_PATTERN.finditer(text):
        body_start = match.end() - 1
        depth = 0
        i = body_start
        while i < len(text):
            ch = text[i]
            if ch == '"':
                literal_end = _skip_swift_string_literal(text, i)
                prefix = text[max(body_start, i - 60):i]
                line = prefix.rsplit("\n", 1)[-1]
                # Returned copy, in the spellings a label property actually uses: a `switch` arm
                # (`case .a: return "Alpha"`, or the implicit-return form), or a ternary.
                #
                # A bare "ends with a colon" test is NOT enough to spot a case arm: every argument label
                # ends the same way, so `joined(separator: ", ")` looked like returned copy and the
                # separator was reported as untranslated UI.
                #
                # Keyed on the RETURN, not on brace depth. Depth alone looked right and silently missed
                # the commoner shape: a `switch` opens a second brace level, so every `case ... return`
                # arm sat a level deeper than the ternary this rule was first written against, and the
                # dominant form in this repository went unchecked.
                stripped = line.lstrip()
                returned = (
                    "return" in line                       # `return "Alpha"`
                    or "?" in line                         # `cond ? "Alpha" : "Beta"`
                    or stripped.startswith(("case ", "default"))  # `case .a: "Alpha"` (implicit return)
                )
                # `String(localized: "...")` is the sanctioned spelling for a String-typed value, so this
                # rule leaves it alone. SWIFT_CALL_START_PATTERN is what checks its catalog key, a
                # delegation that was only asserted in this comment until it was made true.
                if returned and "localized:" not in prefix:
                    yield i, text[i + 1:literal_end - 1]
                i = literal_end
                continue
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    break
            i += 1


def swift_catalog_pattern(literal: str) -> re.Pattern[str] | None:
    """Turn a Swift source literal into a regex for its compiled catalog key."""
    parts: list[str] = []
    cursor = 0
    i = 0
    found_interpolation = False
    while i < len(literal):
        if literal.startswith("\\(", i):
            found_interpolation = True
            static = swift_unescape(literal[cursor:i]).replace("%", "%%")
            parts.append(re.escape(static))
            depth = 1
            i += 2
            in_string = False
            while i < len(literal) and depth:
                ch = literal[i]
                if in_string:
                    if ch == "\\" and i + 1 < len(literal):
                        i += 2
                        continue
                    if ch == '"':
                        in_string = False
                elif ch == '"':
                    in_string = True
                elif ch == "(":
                    depth += 1
                elif ch == ")":
                    depth -= 1
                i += 1
            parts.append(CATALOG_PLACEHOLDER_PATTERN)
            cursor = i
        else:
            i += 1
    if not found_interpolation:
        return None
    parts.append(re.escape(swift_unescape(literal[cursor:]).replace("%", "%%")))
    return re.compile("^" + "".join(parts) + "$")


def swift_unescape(value: str) -> str:
    """Decode the Swift escapes that can appear in catalog source text."""
    value = re.sub(r"\\u\{([0-9A-Fa-f]+)\}", lambda m: chr(int(m.group(1), 16)), value)
    replacements = {
        r'\"': '"',
        r"\'": "'",
        r"\n": "\n",
        r"\r": "\r",
        r"\t": "\t",
        r"\\": "\\",
    }
    for escaped, decoded in replacements.items():
        value = value.replace(escaped, decoded)
    return value


def swift_catalog_lookup(cat: dict, literal: str) -> dict | None:
    """Find a direct or compiler-normalized String Catalog entry."""
    direct = catalog_lookup(cat, swift_unescape(literal))
    if direct is not None:
        return direct
    pattern = swift_catalog_pattern(literal)
    if pattern is None:
        return None
    for key, entry in cat.get("strings", {}).items():
        if pattern.fullmatch(key):
            return entry
    return None


APPLE_FORMAT_PATTERN = re.compile(
    r"%(?:(?:\d+)\$)?(@|(?:hh|h|ll|l|q|z|t|j)?[diuoxXfFeEgGaAcCsSp])"
)


def _string_units(entry: dict, lang: str) -> list[dict]:
    """Every stringUnit a localization carries — plain value OR plural variations.

    An xcstrings localization is either

        localizations.<lang>.stringUnit

    or, once the string has plural forms,

        localizations.<lang>.variations.plural.<category>.stringUnit

    (device variations nest the same way, and the two can combine). Reading only the FIRST shape makes
    every pluralised entry look untranslated to this gate — so converting a hand-rolled ternary into real
    plural variations would red-flag the string in every language. Walk both shapes.
    """
    loc = (entry.get("localizations", {}) or {}).get(lang) or {}
    units: list[dict] = []
    unit = loc.get("stringUnit")
    if isinstance(unit, dict):
        units.append(unit)

    def walk(node: object) -> None:
        if not isinstance(node, dict):
            return
        for key, value in node.items():
            if key == "stringUnit" and isinstance(value, dict):
                units.append(value)
            elif isinstance(value, dict):
                walk(value)

    walk(loc.get("variations") or {})
    return units


def _is_translated(entry: dict, lang: str) -> bool:
    """True when the localization exists AND every one of its stringUnits is translated — so a plural
    with one category still marked `new` is correctly reported as a gap, not silently accepted."""
    units = _string_units(entry, lang)
    return bool(units) and all(u.get("state") == "translated" for u in units)


def apple_format_gaps(cat: dict, lang: str) -> list[str]:
    """Catalog keys whose localized printf arguments differ from the source."""
    def signature(value: str) -> list[str]:
        return sorted(APPLE_FORMAT_PATTERN.findall(value))

    mismatched = []
    for key, entry in cat.get("strings", {}).items():
        if entry.get("shouldTranslate") is False:
            continue
        # Compare EVERY form independently against the key, never a folded concatenation: folding would
        # make the signature depend on how many plural categories the language HAS (ru/pl carry four,
        # zh one), so a correct translation would read as a format mismatch purely for having more forms.
        # An ABSENT localization is a coverage gap, reported by the missing/allowance counters, and
        # must not be read as a format mismatch. `or [""]` used to make one look like the other: the
        # empty signature differs from any key carrying a specifier. That never showed for the focus
        # languages, which are held at zero missing, and it turned every ratcheted gap in it/ru/pl
        # into a false format failure the moment this check was widened past them.
        values = [u.get("value", "") for u in _string_units(entry, lang)]
        if not values:
            continue
        if any(signature(key) != signature(v) for v in values):
            mismatched.append(key)
    return mismatched


def load_catalog(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def catalog_lookup(cat: dict, key: str) -> dict | None:
    return cat.get("strings", {}).get(key)


def scan_ios(read: Reader | None = None) -> tuple[list[tuple[str, int, str]], dict[str, list[str]]]:
    read = read or _disk_read
    hardcoded: list[tuple[str, int, str]] = []  # not in any catalog at all
    lang_gaps: dict[str, list[str]] = {lang: [] for lang in LANGS}

    for dirs, catalog_path in CATALOGS:
        cat_text = read(catalog_path)
        cat = json.loads(cat_text) if cat_text else {"strings": {}}
        for base in dirs:
            if not base.exists():
                continue
            for path in sorted(base.rglob("*.swift")):
                text = read(path) or ""
                literals = list(swift_string_literals(text))
                # Screen files only: see `swift_returned_copy_literals` for why the same shape
                # elsewhere (BLE opcode names, design-system internals) is not copy.
                if "/Screens/" in path.as_posix() or "/Liquid/" in path.as_posix():
                    literals += list(swift_returned_copy_literals(text))
                for offset, literal in literals:
                    if not is_probably_ui_text(literal):
                        continue
                    entry = swift_catalog_lookup(cat, literal)
                    line_no = text.count("\n", 0, offset) + 1
                    rel = path.relative_to(ROOT).as_posix()
                    if entry is None:
                        hardcoded.append((rel, line_no, literal))
                        continue
                    if entry.get("shouldTranslate") is False:
                        continue
                    for lang in LANGS:
                        if not _is_translated(entry, lang):
                            lang_gaps[lang].append(f"{catalog_path.relative_to(ROOT).as_posix()} :: {literal!r}")
    for lang in lang_gaps:
        lang_gaps[lang] = sorted(set(lang_gaps[lang]))
    return hardcoded, lang_gaps


# Languages the audit hard-gates at ZERO missing keys. Historically the ONLY languages it looked at
# — which is why they sit at 100% while everything else drifted. Unchanged here: still zero tolerance.
#
# Every OTHER shipped locale is discovered below and gated against a ratcheting allowance instead, so
# switching coverage on does not red-check every open PR with hundreds of pre-existing gaps (#844).
EXTRA_LOCALE_BASELINE_PATH = ROOT / "Tools/i18n_extra_locale_baseline.txt"


def shipped_apple_langs(cat: dict) -> set[str]:
    """Every non-English localization the catalog actually carries.

    Read from the catalog rather than a constant so a language is covered the day it appears. The
    hardcoded LANGS is what let `it`, `ru`, `zh-Hans` and `zh-Hant` ship for months at up to 85%
    untranslated while the audit reported green (#844).
    """
    langs: set[str] = set()
    for v in cat.get("strings", {}).values():
        langs |= set((v.get("localizations") or {}).keys())
    return langs - {"en"}


def extra_locale_allowance() -> dict[str, int]:
    """`target -> allowed missing count` for the newly-covered locales.

    Counts rather than key lists, for the same reason as Tools/doc_comment_lint_baseline.txt: a key
    list goes stale on every edit and trains people to regenerate it unread, while a count moves only
    when someone adds or removes a gap. Ratchets DOWN — closing gaps prints an IMPROVED line.
    """
    if not EXTRA_LOCALE_BASELINE_PATH.exists():
        return {}
    out: dict[str, int] = {}
    for raw in EXTRA_LOCALE_BASELINE_PATH.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        target, _, count = line.rpartition(" ")
        out[target.strip()] = int(count)
    return out


ECHO_BASELINE_PATH = ROOT / "Tools/i18n_echo_baseline.txt"

#: Format specifiers stripped before deciding whether a string has translatable words in it. Covers
#: the Apple conversion shapes (`%@`, `%lld`) as well as positional `%1$s`-style ones.
FORMAT_SPECIFIER_PATTERN = re.compile(r"%(?:\d+\$)?[@#0\-+ ]*[\d.]*(?:ll|l|h)?[@dfsu]|%%")


# Multi-word product names that travel verbatim into Latin-script locales. The two-word floor below
# already lets a ONE-word brand through ("HRV", "Strava"); it cannot see a two-word one, so "iCloud
# Drive" repeated verbatim in German reads as an untranslated echo when it is the correct rendering.
# Only strings that are ENTIRELY brand are exempted (see `_is_pure_brand_phrase`), so "Apple Health
# sync" stays gated on its translatable word. CJK locales that DO translate these are unaffected —
# they differ from the source, so they were never counted as echoes in the first place.
BRAND_PHRASES = ("iCloud Drive",)


def _is_pure_brand_phrase(text: str) -> bool:
    """Whether a string is nothing but brand names, placeholders and punctuation."""
    stripped = FORMAT_SPECIFIER_PATTERN.sub(" ", text)
    for brand in BRAND_PHRASES:
        stripped = stripped.replace(brand, " ")
    return not re.search(r"[^\W\d_]{2,}", stripped, flags=re.UNICODE)


def _has_translatable_words(text: str) -> bool:
    """Whether a string carries enough real words that an identical translation is suspicious.

    Strips format specifiers first: "%@ · n = %lld" / "%1$s: %2$s" are placeholders and punctuation
    with nothing to translate, so a locale repeating them verbatim is CORRECT, not a gap. Two words is
    the floor — one word is very often a term that legitimately travels ("HRV", "Yoga", a brand name).
    A string that is entirely a multi-word brand is the same case one size up (see [BRAND_PHRASES]).
    """
    if _is_pure_brand_phrase(text):
        return False
    stripped = FORMAT_SPECIFIER_PATTERN.sub(" ", text)
    return len(re.findall(r"[^\W\d_]{2,}", stripped, flags=re.UNICODE)) >= 2


def _ios_echoed_counts() -> dict[str, int]:
    """`<catalog> <lang> -> count` of xcstrings localizations marked `translated` whose value IS the
    English key (in a String Catalog the key is the source string)."""
    counts: dict[str, int] = {}
    for _dirs, catalog_path in CATALOGS:
        if not catalog_path.is_file():
            continue
        try:
            cat = json.loads(catalog_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        rel = catalog_path.relative_to(ROOT).as_posix()
        for key, entry in (cat.get("strings") or {}).items():
            if not _has_translatable_words(key):
                continue
            for lang, unit in (entry.get("localizations") or {}).items():
                if lang == "en":
                    continue
                su = unit.get("stringUnit") or {}
                if su.get("state") == "translated" and su.get("value") == key:
                    counts[f"{rel} {lang}"] = counts.get(f"{rel} {lang}", 0) + 1
    return counts


def echoed_translation_counts() -> dict[str, int]:
    """`<catalog> <lang> -> count` of localizations that are still the English source.

    The hole this closes: the coverage gate asks whether a key EXISTS in a language, never whether the
    value differs from the source. A catalog can therefore be 100% "complete" while a German reader sees
    English sentences — which is exactly what shipped once (a German goal card whose body read "Add a
    daily action …").

    Counts rather than a key list, for the reason `extra_locale_allowance` gives: a list goes stale on
    every edit and trains people to regenerate it unread. NOT every hit is a missing translation — a
    brand ("Apple Health"), a design-system label ("Headline / Semibold 17") or a term of art
    legitimately reads the same in every language — which is why this RATCHETS against a baseline instead
    of demanding zero: the gate's job is to stop the number GROWING, and the residue is a work list to
    draw down by hand.
    """
    return _ios_echoed_counts()


def echo_allowance() -> dict[str, int]:
    """`<catalog> <lang> -> allowed echo count`, same shape and ratchet as
    `extra_locale_allowance`."""
    if not ECHO_BASELINE_PATH.exists():
        return {}
    out: dict[str, int] = {}
    for raw in ECHO_BASELINE_PATH.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        target, _, count = line.rpartition(" ")
        out[target.strip()] = int(count)
    return out


BASELINE_PATH = ROOT / "Tools/i18n_audit_baseline.json"


def load_baseline() -> dict[str, set[tuple[str, str]]]:
    """Pre-existing hardcoded-literal findings, keyed by (path, literal) —
    not line number, which drifts on any unrelated edit to the same file.

    #540's scanner fix went from missing whole classes of conditionally-
    hidden literals to correctly finding hundreds of real ones once it could
    see through ternaries and nested calls — far more than one PR can respect
    while writing careful, non-machine-slop translations for (see #543 on what
    rushing that produces). This baseline lets the scanner itself land
    immediately — CI blocks any NEW hardcoded literal from this point on —
    while the pre-existing backlog is closed incrementally in separate,
    appropriately-sized follow-up PRs. Regenerate with `--update-baseline`
    after closing some of it; an entry that no longer appears in a fresh scan
    is simply inert, not an error.

    Only the "ios" key is read. Any other top-level key an older baseline
    file may still carry is ignored rather than rejected."""
    if not BASELINE_PATH.exists():
        return {"ios": set()}
    data = json.loads(BASELINE_PATH.read_text(encoding="utf-8"))
    return {"ios": {(p, lit) for p, lit in data.get("ios", [])}}


def write_baseline() -> None:
    ios_hardcoded, _gaps = scan_ios()
    ios = sorted({(p, lit) for p, _line, lit in ios_hardcoded})
    BASELINE_PATH.write_text(
        json.dumps({"ios": ios}, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    print(f"Wrote {len(ios)} ios entries to {BASELINE_PATH.relative_to(ROOT)}")


def _disk_read(path: Path) -> str | None:
    if not path.exists():
        return None
    return path.read_text(encoding="utf-8", errors="replace")


def git_show(ref: str, rel_path: str) -> str | None:
    """File content at `ref`, or None if the path didn't exist there."""
    result = subprocess.run(
        ["git", "show", f"{ref}:{rel_path}"],
        cwd=ROOT, capture_output=True, text=True,
    )
    return result.stdout if result.returncode == 0 else None


def ref_reader(ref: str) -> Reader:
    """A `Reader` backed by `git show ref:<path>` instead of disk, for diffing
    the current tree against a base ref. Uses the CURRENT file list (a file
    added by the PR simply reads as empty at the base ref, which correctly
    counts its literals as new)."""
    def read(path: Path) -> str | None:
        return git_show(ref, str(path.relative_to(ROOT)))
    return read


def apple_missing_and_format_gaps(
    read: Reader | None = None,
) -> tuple[dict[tuple[str, str], set[str]], dict[tuple[str, str], set[str]]]:
    """Per (catalog, lang): the set of catalog keys missing a translation, and
    the set of catalog keys whose translated printf arguments don't match."""
    read = read or _disk_read
    missing: dict[tuple[str, str], set[str]] = {}
    formats: dict[tuple[str, str], set[str]] = {}
    for _dirs, catalog_path in CATALOGS:
        cat_text = read(catalog_path)
        cat = json.loads(cat_text) if cat_text else {"strings": {}}
        rel = str(catalog_path.relative_to(ROOT))
        for lang in LANGS:
            keys_missing = {
                key for key, entry in cat.get("strings", {}).items()
                if entry.get("shouldTranslate") is not False and not _is_translated(entry, lang)
            }
            if keys_missing:
                missing[(rel, lang)] = keys_missing
            fmt_gaps = set(apple_format_gaps(cat, lang))
            if fmt_gaps:
                formats[(rel, lang)] = fmt_gaps
    return missing, formats


def ci_check(base_ref: str) -> int:
    """CI gate, exempting a violation on either of two independent grounds:

    1. It's in the committed baseline (Tools/i18n_audit_baseline.json) — the
       backlog #540/#558's improved scanner surfaced, tracked so it can be
       closed incrementally instead of blocking the scanner fix itself.
    2. It already exists at `base_ref` — so this PR didn't cause it. A prior
       version of this gate audited the whole tree unconditionally, ignoring
       base_ref entirely: a transient regression on `base_ref` itself (e.g. a
       release generating a raw literal, #514) then red-flagged every open PR
       whose diff never touched the offending file, and those PRs stayed red
       until they got a fresh push, because a GitHub `pull_request` workflow
       doesn't re-run just because the base branch changed. The baseline
       alone doesn't cover this case — it's a fixed snapshot, so a *new*
       regression on main after the snapshot was taken would still red-flag
       every unrelated PR until someone updates the baseline. Diffing against
       `base_ref` closes that gap: a violation already present there isn't
       this PR's fault regardless of whether it made it into the baseline,
       so a main-side regression is self-contained to whoever caused it
       instead of spreading.

    Locale-gap and format-mismatch checks aren't in the baseline (it only
    tracks hardcoded literals) — the base_ref diff is their only exemption,
    which is sufficient since that backlog is fully closed today.
    """
    base_read = ref_reader(base_ref)
    failed = False
    baseline = load_baseline()

    print(f"--- Apple: no new un-extracted UI copy or focus-locale gaps vs {base_ref} ---")
    cur_ios, _cur_ios_lang_gaps = scan_ios()
    ios_found = {(p, lit) for p, _line, lit in cur_ios}
    base_ios_keys = {(path, literal) for path, _line, literal in scan_ios(base_read)[0]}
    exempt_ios = baseline["ios"] | base_ios_keys
    new_ios = [f for f in cur_ios if (f[0], f[2]) not in exempt_ios]
    if new_ios:
        failed = True
        print(f"FAIL {len(new_ios)} new literal(s) absent from their target catalog:")
        for path, line, literal in new_ios[:30]:
            print(f"  {path}:{line}: {literal!r}")
    else:
        note = f" ({len(ios_found)} pre-existing, tracked in the baseline or on {base_ref})" if ios_found else ""
        print(f"  OK no new un-extracted literals{note}")
    ios_fixed = baseline["ios"] - ios_found
    if ios_fixed:
        print(f"  {len(ios_fixed)} baseline entr(y/ies) no longer found — run --update-baseline to shrink the backlog")
    allowance = extra_locale_allowance()
    extra_apple_gaps: dict[str, int] = {}
    cur_missing, cur_fmt = apple_missing_and_format_gaps()
    base_missing, base_fmt = apple_missing_and_format_gaps(base_read)
    for _dirs, catalog_path in CATALOGS:
        rel = str(catalog_path.relative_to(ROOT))
        # #844: count the shipped locales OUTSIDE the focus set while the catalog is already parsed,
        # and gate them below. Reloading each catalog for a second pass wasted a full re-parse of a
        # 3255-string file. Deliberately disk-based like the rest of this ratchet (not base_ref-diffed
        # like the LANGS check below): the allowance file is already the mechanism that keeps a main-side
        # change here from spreading to unrelated PRs, by tracking a target count instead of demanding
        # zero, so it doesn't need base_ref's protection on top.
        cat = load_catalog(catalog_path)
        for extra in sorted(shipped_apple_langs(cat) - set(LANGS)):
            extra_apple_gaps[f"{rel}:{extra}"] = sum(
                1 for v in cat.get("strings", {}).values()
                if v.get("shouldTranslate") is not False and not _is_translated(v, extra)
            )
            # COVERAGE for these locales is ratcheted, because they carry inherited gaps that would
            # red-check every open PR. FORMAT is not: a specifier the translation drops or invents is
            # a runtime substitution bug, not a gap, and it is exactly as broken in Russian as in
            # German. Checking it only for LANGS left zh, it, ru and pl free to ship a dropped `%@`
            # through a green board, which is how `%lld app%@ on` and `%lld frame%@ captured this
            # session.` kept a Russian mismatch each for as long as they existed. Zero tolerance
            # here is affordable because the count across every catalogue and every locale is now 0.
            extra_format_gaps = apple_format_gaps(cat, extra)
            if extra_format_gaps:
                failed = True
                print(f"FAIL {catalog_path.relative_to(ROOT)} {extra}: "
                      f"{len(extra_format_gaps)} format mismatch(es): {extra_format_gaps[:10]}")
        for lang in LANGS:
            key = (rel, lang)
            new_missing = sorted(cur_missing.get(key, set()) - base_missing.get(key, set()))
            if new_missing:
                failed = True
                print(f"FAIL {rel} {lang}: {len(new_missing)} new missing translation(s): {new_missing[:30]}")
            else:
                print(f"  OK {rel} {lang}")
            new_fmt_gap = sorted(cur_fmt.get(key, set()) - base_fmt.get(key, set()))
            if new_fmt_gap:
                failed = True
                print(f"FAIL {rel} {lang}: {len(new_fmt_gap)} new format mismatch(es): {new_fmt_gap[:10]}")

    # A key that EXISTS in a language still says nothing about whether it was TRANSLATED. This section is
    # the difference between "complete" and "translated": it counts localizations whose value is the
    # English source verbatim. See `echoed_translation_counts`.
    print("\n--- Translations that are still the English source (ratcheting allowance) ---")
    echo_failed = False
    echoes = echoed_translation_counts()
    echo_allowed = echo_allowance()
    echo_improved: list[str] = []
    for target in sorted(set(echoes) | set(echo_allowed)):
        found = echoes.get(target, 0)
        allowed = echo_allowed.get(target, 0)
        if found > allowed:
            failed = True
            echo_failed = True
            print(f"FAIL {target}: {found} untranslated echo(es) exceeds the allowance of {allowed}")
        elif found < allowed:
            echo_improved.append(f"{target}: {allowed} -> {found}")
    for line in echo_improved:
        print(f"  IMPROVED {line}")
    if echo_improved:
        print(f"  Lower these in {ECHO_BASELINE_PATH.relative_to(ROOT)} to lock the gain in.")
    if not echo_failed and not echo_improved:
        print(f"  OK no new English-only translations ({sum(echoes.values())} tracked, ratcheting down)")

    # #844: every OTHER shipped locale, gated against a ratcheting allowance. LANGS above stays at zero
    # tolerance; these carry real pre-existing debt (StrandDesign ships 14 of 95 Italian), so the gate
    # blocks GROWTH rather than demanding the backlog be cleared before anyone can merge.
    print("\n--- Locales beyond the focus set: no NEW gaps (ratcheting allowance) ---")
    # Local, NOT the global `failed`: an earlier section failing (a German string, an un-extracted
    # literal) must not silence this section's own verdict. Reporting nothing here reads as "did not
    # run", which is the worst thing a gate can say to someone trying to understand a red build.
    locale_failed = False
    improved: list[str] = []
    seen_targets: set[str] = set()
    for target, missing in sorted(extra_apple_gaps.items()):
        seen_targets.add(target)
        allowed = allowance.get(target, 0)
        if missing > allowed:
            failed = True
            locale_failed = True
            print(f"FAIL {target}: missing={missing} exceeds the allowance of {allowed}")
        elif missing < allowed:
            improved.append(f"{target}: {allowed} -> {missing}")
    # An allowance for a target that no longer exists (locale removed, catalog dropped) can never be
    # satisfied and silently inflates the tracked total, so surface it rather than let it rot.
    for stale in sorted(set(allowance) - seen_targets):
        print(f"  STALE {stale} is no longer present — drop it from {EXTRA_LOCALE_BASELINE_PATH.name}.")
    for line in improved:
        print(f"  IMPROVED {line}. Lower it in {EXTRA_LOCALE_BASELINE_PATH.name}.")
    if not locale_failed:
        tracked = sum(allowance.values())
        print(f"  OK no new gaps in the non-focus locales ({tracked} tracked, ratcheting down)")

    return 1 if failed else 0


def catalog_summary() -> None:
    print("\n--- Apple catalogs: translated-key coverage (existing keys, any source) ---")
    for _dirs, catalog_path in CATALOGS:
        cat = load_catalog(catalog_path)
        strings = cat.get("strings", {})
        total = len(strings)
        line = f"{catalog_path.relative_to(ROOT)} ({total} keys):"
        # #844: report every locale the catalog actually ships, not just the focus four. Showing only
        # LANGS is very likely WHY the drift went unnoticed for so long — this summary read 100% across
        # the board while `it` sat at 14 of 95. The gate and the human-readable view must see the same
        # set, or the view quietly reassures you about languages nobody is checking.
        for lang in sorted(set(LANGS) | shipped_apple_langs(cat)):
            missing = 0
            for v in strings.values():
                if v.get("shouldTranslate") is False:
                    continue
                # Via `_is_translated`, NOT a bare `localizations[lang].stringUnit.state` read: a
                # pluralised entry keeps its units under `variations.plural.<category>.stringUnit`, so the
                # flat lookup returns None and scores a fully-translated plural as a gap. That is the exact
                # trap `_string_units` was written for, and this summary was the one caller still falling
                # into it — reporting de/es/fr/pt-PT missing=4 and pl missing=5 on the Strand catalog when
                # every one of those entries was translated in every form. Worse than a wrong number: it
                # sent a reader to re-translate strings that were already done, and it made Polish look
                # like the worst-covered language precisely BECAUSE it correctly carries one/few/many/other
                # where the others need only a flat unit.
                if not _is_translated(v, lang):
                    missing += 1
            line += f"  {lang} missing={missing}"
        print(" ", line)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--full", action="store_true", help="print every finding, not just counts")
    ap.add_argument("--ci", metavar="BASE_REF", help="coverage gate: fail only on violations new vs BASE_REF or the baseline; see ci_check() docstring")
    ap.add_argument("--update-baseline", action="store_true", help="rewrite Tools/i18n_audit_baseline.json from the current hardcoded-literal scan (see load_baseline() docstring). Does NOT touch Tools/i18n_extra_locale_baseline.txt — that one is lowered by hand, so shrinking it stays a deliberate act")
    args = ap.parse_args()

    if args.update_baseline:
        write_baseline()
        return 0

    if args.ci:
        return ci_check(args.ci)

    print("=== Apple: hardcoded/un-extracted Swift literals (not in any catalog) ===")
    hardcoded, lang_gaps = scan_ios()
    print(f"{len(hardcoded)} literal(s) not present in their target's String Catalog")
    if args.full:
        for rel, line_no, literal in hardcoded:
            print(f"  {rel}:{line_no}: {literal!r}")
    else:
        for rel, line_no, literal in hardcoded[:25]:
            print(f"  {rel}:{line_no}: {literal!r}")
        if len(hardcoded) > 25:
            print(f"  ... and {len(hardcoded) - 25} more (use --full)")

    print("\n=== Apple: catalog keys present but not translated, per language ===")
    for lang in LANGS:
        entries = lang_gaps[lang]
        print(f"  {lang}: {len(entries)} gap(s)")
        if args.full:
            for e in entries:
                print(f"    {e}")

    catalog_summary()

    return 0


if __name__ == "__main__":
    sys.exit(main())
