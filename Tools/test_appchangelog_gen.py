#!/usr/bin/env python3
"""Pins the shape of the generated What's New entry and the refresh-on-rerun behaviour of `apply()`.

The title stays a plain Swift literal (SwiftUI auto-extracts it into the String Catalog), and re-running
the generator after editing a headline must update the existing entry rather than leave it stale.
"""
import importlib.util
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("acg", ROOT / "Tools/appchangelog-gen.py")
acg = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(acg)

SHIPPED_TITLE = ("Battery saver quiets the gauges, translated notifications, "
                 "and instant chart loads")


class EmittedBlockTests(unittest.TestCase):

    WN = {"title": SHIPPED_TITLE, "date": "July 2026", "items": ["**One.** A thing."]}

    def test_swift_title_stays_a_literal(self):
        """SwiftUI auto-extracts into the catalog, so Apple needs no resource reference — and changing
        it would break the baseline that tracks these titles."""
        block = acg.sw_block("9.2.1", self.WN)
        self.assertIn(f'title: "{SHIPPED_TITLE}"', block)

    def test_items_stay_literals(self):
        """Items are long-form prose the gate does not require extracting."""
        block = acg.sw_block("9.2.1", self.WN)
        self.assertIn('"**One.** A thing."', block)

    def test_quotes_and_backslashes_are_escaped(self):
        block = acg.sw_block("1.0.0", {"title": 'Say "hi" \\ now', "date": "May", "items": ['a "b"']})
        self.assertIn('title: "Say \\"hi\\" \\\\ now"', block)
        self.assertIn('"a \\"b\\""', block)


class TitleRefreshTests(unittest.TestCase):
    """Re-running after editing the headline must update the entry, not leave it stale.

    The bug this pins: `apply()` skipped an entry that already existed, so an edited headline never
    reached the card while the release notes carried the new one, with nothing failing. Found by doing it.
    """

    SW_HEAD = ("enum AppChangelog {\n"
               "    static let currentVersion = \"0.0.0\"\n"
               "    static let releases: [Release] = [\n")
    SW_TAIL = "    ]\n}\n"
    ANCHOR = "static let releases: [Release] = [\n"
    CONST_RE = r'(static let currentVersion = ")[^"]*(")'
    CONST_NEW = r'\g<1>9.9.9\g<2>'

    def _file(self, body):
        f = tempfile.NamedTemporaryFile("w", suffix=".swift", delete=False)
        f.write(self.SW_HEAD + body + self.SW_TAIL)
        f.close()
        return pathlib.Path(f.name)

    ENTRY = ('        Release(\n'
             '            version: "9.9.9",\n'
             '            title: "Old headline",\n'
             '            date: "July 2026",\n'
             '            items: []\n'
             '        ),\n')

    def test_existing_entry_gets_its_title_updated(self):
        path = self._file(self.ENTRY)
        acg.apply(path, self.ANCHOR, "IGNORED", "9.9.9", self.CONST_RE, self.CONST_NEW,
                  title_line='title: "New headline",')
        out = path.read_text()
        self.assertIn('title: "New headline",', out)
        self.assertNotIn("Old headline", out)
        path.unlink()

    def test_it_does_not_duplicate_the_entry(self):
        path = self._file(self.ENTRY)
        acg.apply(path, self.ANCHOR, "SHOULD_NOT_APPEAR", "9.9.9", self.CONST_RE, self.CONST_NEW,
                  title_line='title: "New headline",')
        out = path.read_text()
        self.assertEqual(1, out.count('version: "9.9.9"'))
        self.assertNotIn("SHOULD_NOT_APPEAR", out)
        path.unlink()

    def test_unchanged_title_is_left_alone(self):
        """The ENTRY is untouched when the headline has not moved. Asserting the title line rather than
        the whole file, because `apply()` legitimately rewrites the version constant on every run."""
        same = 'title: "Old headline",'
        path = self._file(self.ENTRY)
        acg.apply(path, self.ANCHOR, "IGNORED", "9.9.9", self.CONST_RE, self.CONST_NEW, title_line=same)
        out = path.read_text()
        self.assertEqual(1, out.count(same))
        self.assertEqual(1, out.count('version: "9.9.9"'))
        self.assertIn('static let currentVersion = "9.9.9"', out)   # the constant DOES move
        path.unlink()

    def test_new_version_is_inserted_at_the_anchor_and_constant_bumped(self):
        path = self._file("")
        wn = {"title": "Fresh", "date": "Aug 2026", "items": ["**A.** b"]}
        acg.apply(path, self.ANCHOR, acg.sw_block("9.9.9", wn), "9.9.9", self.CONST_RE, self.CONST_NEW,
                  title_line='title: "Fresh",')
        out = path.read_text()
        self.assertIn('version: "9.9.9"', out)
        self.assertIn('static let currentVersion = "9.9.9"', out)
        path.unlink()


if __name__ == "__main__":
    unittest.main()
