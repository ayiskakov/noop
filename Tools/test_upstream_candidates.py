#!/usr/bin/env python3
"""Pins what upstream-candidates.py hides, what it calls clean, and what --apply refuses to do.

The tool exists so that an upstream fix is never missed and a decided commit is never listed again.
Both failures are silent: a commit wrongly hidden looks exactly like one that was never there. So
the rules run here against a throwaway repository built in a temporary directory, shaped like the
real history: a fork that deleted android/ and edited a shared file, and upstream commits that are
Android-only, fixed on both platforms, clashing with the fork, already picked, or skip-listed. No
network, and the user's own git configuration is kept out of it.

Standard `unittest`, discovered by `tools-python.yml` alongside the other Tools/ suites.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "upstream_candidates", Path(__file__).resolve().parent / "upstream-candidates.py")
uc = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = uc  # dataclasses resolve their annotations through sys.modules
_spec.loader.exec_module(uc)

TREE = "f" * 40


def entry(stage: int, path: str) -> str:
    return f"100644 {str(stage) * 40} {stage}\t{path}\0"


def _git_at_least(major: int, minor: int) -> bool:
    try:
        out = subprocess.run(["git", "version"], capture_output=True, text=True).stdout
    except OSError:
        return False
    match = re.search(r"(\d+)\.(\d+)", out)
    return bool(match) and (int(match.group(1)), int(match.group(2))) >= (major, minor)


class ParseMergeTree(unittest.TestCase):
    """Stage 1 is the picked commit's parent, 2 is HEAD, 3 is the picked commit."""

    REMOVED = uc.Removed(files={"android/A.kt"})

    def parse(self, out: str):
        return uc.parse_merge_tree(out, self.REMOVED)

    def test_a_clean_pick_is_the_tree_alone(self):
        sim = self.parse(TREE + "\0")
        self.assertEqual(([], []), (sim.conflicts, sim.removed))
        self.assertEqual("clean", sim.describe())

    def test_a_file_this_fork_deleted_is_dropped_not_resolved(self):
        sim = self.parse(TREE + "\0" + entry(1, "android/A.kt") + entry(3, "android/A.kt"))
        self.assertEqual([], sim.conflicts)
        self.assertEqual(["android/A.kt"], sim.removed)
        self.assertEqual("clean, 1 rm", sim.describe())

    def test_a_file_not_here_yet_is_a_conflict_not_a_drop(self):
        # Same stages as a removed file, but nothing removed it: an earlier upstream commit added
        # it. Dropping it would cut the fix's edit to it out of the pick without a word.
        sim = self.parse(TREE + "\0" + entry(1, "Strand/BLE/New.swift") + entry(3, "Strand/BLE/New.swift"))
        self.assertEqual((["Strand/BLE/New.swift"], []), (sim.conflicts, sim.removed))

    def test_both_sides_edited_is_a_conflict(self):
        out = TREE + "\0" + entry(1, "a.swift") + entry(2, "a.swift") + entry(3, "a.swift")
        self.assertEqual(["a.swift"], self.parse(out).conflicts)

    def test_upstream_deleting_what_the_fork_edited_is_a_conflict(self):
        out = TREE + "\0" + entry(1, "a.swift") + entry(2, "a.swift")
        self.assertEqual(["a.swift"], self.parse(out).conflicts)

    def test_both_adding_the_same_path_is_a_conflict(self):
        out = TREE + "\0" + entry(2, "a.swift") + entry(3, "a.swift")
        self.assertEqual(["a.swift"], self.parse(out).conflicts)

    def test_a_real_conflict_outranks_the_dropped_files_in_the_summary(self):
        out = (TREE + "\0" + entry(1, "android/A.kt") + entry(3, "android/A.kt")
               + entry(1, "a.swift") + entry(2, "a.swift") + entry(3, "a.swift"))
        sim = self.parse(out)
        self.assertEqual("1 conflict", sim.describe())
        self.assertEqual(["android/A.kt"], sim.removed)


class Areas(unittest.TestCase):
    def test_the_ble_stack_and_the_protocol_package_are_named(self):
        self.assertEqual(["ble", "protocol"], uc.areas_of([
            "Packages/WhoopProtocol/Sources/WhoopProtocol/Framing.swift",
            "Strand/BLE/BLEManager.swift"]))

    def test_tests_and_docs_give_way_to_the_code_they_accompany(self):
        self.assertEqual(["analytics"], uc.areas_of([
            "Packages/StrandAnalytics/Sources/StrandAnalytics/HRV.swift",
            "Packages/StrandAnalytics/Tests/StrandAnalyticsTests/HRVTests.swift",
            "docs/HRV.md"]))

    def test_a_test_only_commit_says_so(self):
        self.assertEqual(["tests"], uc.areas_of(["StrandTests/FooTests.swift"]))

    def test_a_package_test_is_not_package_code(self):
        self.assertEqual("tests", uc.area_of("Packages/WhoopProtocol/Tests/X/FramingTests.swift"))

    def test_the_ios_health_bridge_is_health_not_app(self):
        self.assertEqual("health", uc.area_of("StrandiOS/Health/HealthKitBridge.swift"))

    def test_a_sweeping_commit_keeps_the_column_short(self):
        self.assertEqual("ble,store,analytics+2",
                         uc.area_tag(["ble", "store", "analytics", "ui", "app"]))
        self.assertEqual("-", uc.area_tag([]))


class RemovedScopeHint(unittest.TestCase):
    def test_subjects_naming_a_removed_device_or_platform(self):
        for subject in ("ble(android): start the keep-alive on a 5/MG (#2391)",
                        "ble: support direct HR broadcast on WHOOP 4.0 (#2400)",
                        "log(oura): say WHICH SpO2 channel (#2408)",
                        "port the Kotlin twin"):
            self.assertIsNotNone(uc.REMOVED_SCOPE.search(subject), subject)

    def test_subjects_that_only_look_close(self):
        for subject in ("today: draw the hero ring flat (#2410)",
                        "stress: print the LF/HF ratio on both platforms (#2369)",
                        "ble: reject a false start-of-frame by its own header checksum (#2429)",
                        "release 14.0.1"):
            self.assertIsNone(uc.REMOVED_SCOPE.search(subject), subject)


class SkipLedger(unittest.TestCase):
    def commit(self, sha="0123456789abcdef" + "0" * 24, subject="x"):
        return uc.Commit(sha, "2026-09-24", subject, [])

    def test_an_abbreviated_sha_matches_the_commit_it_prefixes(self):
        skips = uc.load_skips("0123456 WHOOP 4.0 only (#2400)\n")
        self.assertEqual("WHOOP 4.0 only (#2400)", skips.reason(self.commit()))
        self.assertIsNone(skips.reason(self.commit(sha="f" * 40)))

    def test_a_hash_inside_a_reason_is_not_a_comment(self):
        skips = uc.load_skips("# header\n\n0123456 see #2400 # and #2401\n")
        self.assertEqual("see #2400 # and #2401", skips.reason(self.commit()))

    def test_a_subject_pattern_skips_every_match(self):
        skips = uc.load_skips("/^build: testing build/ upstream's build numbers\n")
        self.assertEqual("upstream's build numbers",
                         skips.reason(self.commit(subject="build: testing build 534 / 415")))
        self.assertIsNone(skips.reason(self.commit(subject="ble: testing build")))

    def test_a_malformed_line_names_its_line(self):
        with self.assertRaisesRegex(ValueError, r"ledger:2:"):
            uc.load_skips("0123456 fine\nnot-a-sha reason\n", "ledger")
        with self.assertRaisesRegex(ValueError, r"ledger:1: bad subject pattern"):
            uc.load_skips("/(unclosed/ reason\n", "ledger")


class PickedTrailer(unittest.TestCase):
    def test_the_line_cherry_pick_x_writes(self):
        sha = "ab" * 20
        body = f"ble: fix\n\nWhy.\n\n(cherry picked from commit {sha})\n"
        self.assertEqual([sha], uc.PICKED_TRAILER.findall(body))

    def test_a_mention_inside_prose_is_not_a_pick(self):
        body = f"see the note (cherry picked from commit {'ab' * 20}) in the log\n"
        self.assertEqual([], uc.PICKED_TRAILER.findall(body))


LINES = "".join(f"line {i}\n" for i in range(10))


def _isolated_env() -> dict[str, str]:
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1",
               GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@example.invalid",
               GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@example.invalid")
    return env


def write(root: Path, path: str, text: str):
    (root / path).parent.mkdir(parents=True, exist_ok=True)
    (root / path).write_text(text)


def edit(root: Path, path: str, index: int, text: str):
    lines = (root / path).read_text().splitlines(keepends=True)
    lines[index] = text + "\n"
    (root / path).write_text("".join(lines))


def commit(git, message: str) -> str:
    git.run("add", "-A")
    git.run("commit", "-q", "-m", message)
    return git.out("rev-parse", "HEAD").strip()


def build_fixture(root: Path, git) -> dict[str, str]:
    """base -> fork (main): deletes android/, edits Engine.swift line 0.
    base -> upstream (up): the commits named below, the last two a chain on one line of one file;
    then the fork takes one with -x and makes another's change by hand. Returns the upstream SHAs
    by name."""
    shas = {}
    git.run("init", "-q", "-b", "main")
    for path in ("Strand/BLE/Framing.swift", "Strand/Collect/Offload.swift",
                 "Strand/Data/Engine.swift", "android/app/Main.kt"):
        write(root, path, LINES)
    write(root, "docs/a.md", "a\n")
    commit(git, "base")
    git.run("branch", "up")

    git.run("rm", "-rq", "android")
    commit(git, "fork: drop android")
    edit(root, "Strand/Data/Engine.swift", 0, "fork line")
    commit(git, "fork: engine")

    git.run("switch", "-q", "up")
    edit(root, "android/app/Main.kt", 3, "android only")
    shas["android_only"] = commit(git, "android: only")
    edit(root, "Strand/BLE/Framing.swift", 5, "ble fix")
    edit(root, "android/app/Main.kt", 5, "kotlin twin")
    shas["both"] = commit(git, "ble: fix on both platforms")
    edit(root, "Strand/Data/Engine.swift", 8, "upstream tweak")
    shas["tweak"] = commit(git, "engine: tweak far from the fork's edit")
    edit(root, "Strand/Data/Engine.swift", 0, "upstream line")
    shas["clash"] = commit(git, "engine: clash")
    write(root, "docs/b.md", "b\n")
    shas["to_pick"] = commit(git, "docs: add b")
    write(root, "docs/a.md", "a2\n")
    shas["declined"] = commit(git, "docs: edit a")
    write(root, "docs/c.md", "c\n")
    shas["same"] = commit(git, "docs: add c")
    write(root, "android/app/New.kt", "new\n")
    shas["new_android"] = commit(git, "android: new file")
    write(root, "Strand/NewFeature/New.swift", "new\n")
    shas["new_dir"] = commit(git, "feature: new directory")
    write(root, "Strand/BLE/Trace.swift", LINES)
    shas["adds_trace"] = commit(git, "ble: add a trace file")
    edit(root, "Strand/BLE/Trace.swift", 4, "trace fix")
    shas["edits_trace"] = commit(git, "ble: fix the trace file")
    edit(root, "Strand/Collect/Offload.swift", 2, "chain one")
    shas["chain1"] = commit(git, "collect: chain one")
    edit(root, "Strand/Collect/Offload.swift", 2, "chain two")
    shas["chain2"] = commit(git, "collect: chain two, on top of chain one")

    git.run("switch", "-q", "main")
    git.run("cherry-pick", "-x", shas["to_pick"])
    write(root, "docs/c.md", "c\n")
    commit(git, "fork: the same change as upstream's docs/c, picked without -x")
    return shas


@unittest.skipUnless(_git_at_least(2, 40), "needs git 2.40+ for merge-tree --merge-base")
class AgainstARepository(unittest.TestCase):
    """Each test gets its own copy of one fixture repository (see build_fixture), built once:
    --apply commits and switches branches, and building ~15 commits per test costs seconds."""

    @classmethod
    def setUpClass(cls):
        cls.env = _isolated_env()
        cls.template = tempfile.TemporaryDirectory()
        cls.shas = build_fixture(Path(cls.template.name), uc.Git(cls.template.name, env=cls.env))

    @classmethod
    def tearDownClass(cls):
        cls.template.cleanup()

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        shutil.copytree(self.template.name, tmp.name, symlinks=True, dirs_exist_ok=True)
        self.root = Path(tmp.name)
        self.git = uc.Git(tmp.name, env=self.env)
        for name, sha in self.shas.items():
            setattr(self, name, sha)

    def rows(self, skips: uc.Skips | None = None) -> dict[str, uc.Row]:
        return {r.commit.subject: r for r in uc.collect(self.git, "HEAD", "up", skips or uc.Skips())}

    def apply(self, *shas: str, allow_main: bool = False) -> tuple[int, str]:
        out = io.StringIO()
        return uc.apply(self.git, list(shas), "up", allow_main, out), out.getvalue()

    # -- what the list hides

    def test_a_commit_touching_only_removed_code_is_hidden(self):
        self.assertEqual("removed only", self.rows()["android: only"].hidden)

    def test_a_new_file_under_a_removed_directory_is_hidden(self):
        self.assertEqual("removed only", self.rows()["android: new file"].hidden)

    def test_a_pick_made_with_x_is_hidden(self):
        self.assertEqual("picked", self.rows()["docs: add b"].hidden)

    def test_the_same_patch_made_without_x_is_hidden(self):
        self.assertEqual("same patch", self.rows()["docs: add c"].hidden)

    def test_a_declined_commit_is_hidden_with_its_reason(self):
        row = self.rows(uc.load_skips(f"{self.declined[:7]} not wanted here\n"))["docs: edit a"]
        self.assertEqual(("skipped", "not wanted here"), (row.hidden, row.reason))

    # -- what it offers, and how it says it applies

    def test_a_new_file_in_a_new_directory_is_offered(self):
        row = self.rows()["feature: new directory"]
        self.assertEqual(("", "clean"), (row.hidden, row.sim.describe()))

    def test_a_fix_on_both_platforms_applies_once_the_removed_twin_is_dropped(self):
        row = self.rows()["ble: fix on both platforms"]
        self.assertEqual(["Strand/BLE/Framing.swift"], row.paths)
        self.assertEqual(["ble"], row.areas)
        self.assertEqual([], row.sim.conflicts)
        self.assertEqual(["android/app/Main.kt"], row.sim.removed)

    def test_an_edit_that_clashes_with_the_fork_is_a_conflict(self):
        self.assertEqual(["Strand/Data/Engine.swift"], self.rows()["engine: clash"].sim.conflicts)

    def test_a_fix_that_builds_on_an_earlier_one_applies_on_top_of_it(self):
        self.assertEqual(["Strand/Collect/Offload.swift"],
                         uc.simulate(self.git, self.chain2, "HEAD", uc.Removed()).conflicts)
        row = self.rows()["collect: chain two, on top of chain one"]
        self.assertEqual(("clean", [self.chain1]), (row.sim.describe(), row.after))

    def test_an_edit_to_a_file_an_earlier_commit_adds_is_never_dropped(self):
        removed = uc.removed_paths(self.git, self.git.out("merge-base", "HEAD", "up").strip(), "HEAD")
        alone = uc.simulate(self.git, self.edits_trace, "HEAD", removed)
        self.assertEqual((["Strand/BLE/Trace.swift"], []), (alone.conflicts, alone.removed))
        row = self.rows()["ble: fix the trace file"]
        self.assertEqual(("clean", [self.adds_trace]), (row.sim.describe(), row.after))

    def test_an_earlier_commit_on_the_same_file_does_not_excuse_a_clash_with_the_fork(self):
        row = self.rows()["engine: clash"]
        self.assertEqual((["Strand/Data/Engine.swift"], []), (row.sim.conflicts, row.after))

    def test_the_listing_shows_only_what_is_left_to_decide(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(0, uc.main(["--upstream", "up"], git=self.git))
        text = out.getvalue()
        self.assertIn("2 only touch code this fork removed · 1 picked with -x · "
                      "1 same patch already here", text)
        self.assertIn("engine: clash", text)
        self.assertNotIn("android: only", text)
        self.assertNotIn("docs: add b", text)

    # -- --apply

    def test_apply_drops_the_removed_twin_and_records_the_origin(self):
        self.git.run("switch", "-q", "-c", "picks")
        code, out = self.apply(self.both[:8])
        self.assertEqual(0, code, out)
        message = self.git.out("log", "-1", "--format=%B")
        self.assertIn(f"(cherry picked from commit {self.both})", message)
        self.assertNotIn("Conflicts", message)
        self.assertFalse((self.root / "android").exists())
        self.assertIn("ble fix", (self.root / "Strand/BLE/Framing.swift").read_text())
        self.assertEqual("picked", self.rows()["ble: fix on both platforms"].hidden)

    def test_apply_takes_commits_in_upstream_order_whatever_order_they_are_given_in(self):
        self.git.run("switch", "-q", "-c", "picks")
        code, out = self.apply(self.new_dir, self.both)
        self.assertEqual(0, code, out)
        subjects = self.git.out("log", "-2", "--format=%s").splitlines()
        self.assertEqual(["feature: new directory", "ble: fix on both platforms"], subjects)

    def test_apply_takes_a_chain_that_only_conflicts_against_head_alone(self):
        self.git.run("switch", "-q", "-c", "picks")
        code, out = self.apply(self.chain2, self.chain1)
        self.assertEqual(0, code, out)
        self.assertIn("chain two", (self.root / "Strand/Collect/Offload.swift").read_text())

    def test_apply_will_not_drop_a_file_that_is_only_missing_because_its_commit_is(self):
        self.git.run("switch", "-q", "-c", "picks")
        head = self.git.out("rev-parse", "HEAD")
        code, out = self.apply(self.edits_trace)
        self.assertEqual(1, code, out)
        self.assertIn("Strand/BLE/Trace.swift", out)
        self.assertEqual(head, self.git.out("rev-parse", "HEAD"))
        code, out = self.apply(self.edits_trace, self.adds_trace)
        self.assertEqual(0, code, out)
        self.assertIn("trace fix", (self.root / "Strand/BLE/Trace.swift").read_text())

    def test_apply_stops_before_a_commit_that_needs_a_hand_resolution(self):
        self.git.run("switch", "-q", "-c", "picks")
        head = self.git.out("rev-parse", "HEAD")
        code, out = self.apply(self.both, self.clash, self.new_dir)
        self.assertEqual(1, code)
        self.assertIn("Strand/Data/Engine.swift", out)
        self.assertIn(f"--apply {self.new_dir[:8]}", out)
        self.assertEqual("ble: fix on both platforms", self.git.out("log", "-1", "--format=%s").strip())
        self.assertNotEqual(head, self.git.out("rev-parse", "HEAD"))
        self.assertEqual("", self.git.out("status", "--porcelain", "--untracked-files=no"))
        self.assertIsNone(uc._in_progress(self.git))

    def test_apply_refuses_main_and_a_dirty_tree(self):
        code, out = self.apply(self.both)
        self.assertEqual(2, code)
        self.assertIn("onto main", out)
        self.git.run("switch", "-q", "-c", "picks")
        edit(self.root, "Strand/BLE/Framing.swift", 9, "uncommitted")
        code, out = self.apply(self.both)
        self.assertEqual(2, code)
        self.assertIn("tracked files have changes", out)

    def test_apply_does_not_take_a_commit_twice(self):
        self.git.run("switch", "-q", "-c", "picks")
        head = self.git.out("rev-parse", "HEAD")
        code, out = self.apply(self.to_pick)
        self.assertEqual(0, code, out)
        self.assertIn("already here", out)
        self.assertEqual(head, self.git.out("rev-parse", "HEAD"))


if __name__ == "__main__":
    unittest.main()
