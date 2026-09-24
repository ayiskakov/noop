#!/usr/bin/env python3
"""List the upstream commits this fork has not taken yet, and say which of them apply cleanly.

Merging `upstream/main` wholesale stopped being practical once this fork removed Android, the
Oura/Polar/Huami peripherals and WHOOP 4.0. Upstream lands around twenty-five commits a day, most of
them to code that no longer exists here: a dry-run merge of three days of it (September 2026) came
to 84 conflicts, 72 of them in deleted files. What the fork still wants is upstream's fixes to the
code the two share, the BLE stack above all, which upstream hardens against many straps and
firmware versions. Those are taken one at a time with `git cherry-pick -x`, and this tool finds them.

Hidden from the list, each counted in the header (`--all` lists them with the reason):

* commits that only touch code this fork removed: a file deleted here since the merge-base, or any
  path under a directory that no longer exists here. A file the fork renamed still counts as kept.
* commits already taken: a `(cherry picked from commit <sha>)` trailer in this branch's history,
  which `-x` writes, or a commit here with the same patch id (a pick made without `-x`).
* commits listed in Tools/upstream-skip.txt: reviewed, and deliberately not taken.

Every remaining commit is cherry-picked in simulation against HEAD with `git merge-tree`, which
touches neither the index nor the working tree, and reported as one of:

    clean           applies as it is
    clean, N rm     applies once the N files it edits that this fork removed are dropped again
    N conflicts     needs a hand resolution in N files (-v names them)

`--apply <sha>...` picks the given commits in upstream order with `-x`. When a pick's only conflicts
are files this fork removed, it drops them (`git rm`) and continues. It re-simulates each commit
against the moving HEAD first and stops BEFORE one that would need a hand resolution, so it never
leaves behind a half-applied pick it did not plan.

Needs git 2.40 or later (`merge-tree --merge-base`).

Usage:
    Tools/upstream-candidates.py                     # what is new on upstream/main
    Tools/upstream-candidates.py --fetch --area ble,protocol
    Tools/upstream-candidates.py -v                  # files touched, conflicts, skip reasons
    Tools/upstream-candidates.py --all               # hidden commits too, with the reason
    Tools/upstream-candidates.py --apply f15360da dab0efe3
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath
from typing import Container, TextIO

DEFAULT_UPSTREAM = "upstream/main"
SKIP_FILE = "Tools/upstream-skip.txt"

# `git merge-tree --merge-base` arrived in 2.40; `--write-tree` alone is not enough to simulate a
# cherry-pick, because without it the merge base is computed rather than the picked commit's parent.
MIN_GIT = (2, 40)

# A subject naming something this fork removed. Only a hint, shown as "~" beside the row: a commit
# titled for both platforms can still carry the iOS half of a fix, and one naming Oura can touch
# shared BLE code.
REMOVED_SCOPE = re.compile(r"\b(?:android|kotlin|oura|polar|huami|gen3|whoop 4(?:\.0)?|4\.0)\b",
                           re.IGNORECASE)

# What `git cherry-pick -x` appends to the message.
PICKED_TRAILER = re.compile(r"^\(cherry picked from commit ([0-9a-f]{40})\)$", re.MULTILINE)

# First match wins. Tests inside a package are their own area (see area_of), so a commit that only
# re-pins a test does not read as a protocol fix.
AREA_PREFIXES = (
    ("Strand/BLE/", "ble"),
    ("Strand/Collect/", "ble"),
    ("Packages/WhoopProtocol/", "protocol"),
    ("Packages/WhoopStore/", "store"),
    ("Packages/NoopLocalAccess/", "store"),
    ("Packages/StrandAnalytics/", "analytics"),
    ("Packages/StrandImport/", "import"),
    ("Strand/Data/", "data"),
    ("Strand/Health/", "health"),
    ("StrandiOS/Health/", "health"),
    ("Packages/StrandDesign/", "ui"),
    ("Strand/Screens/", "ui"),
    ("Strand/Liquid/", "ui"),
    ("StrandTests/", "tests"),
    ("Strand/", "app"),
    ("StrandiOS", "app"),
    ("NOOPWatch", "app"),
    ("project.yml", "build"),
    (".github/", "ci"),
    ("Tools/", "tools"),
    ("docs/", "docs"),
)
AREA_ORDER = ("ble", "protocol", "store", "analytics", "data", "health", "import", "ui", "app",
              "build", "ci", "tools", "docs", "tests", "other")


class GitError(RuntimeError):
    def __init__(self, args: tuple[str, ...], proc: subprocess.CompletedProcess):
        super().__init__(f"git {' '.join(args)} exited {proc.returncode}: {proc.stderr.strip()}")


class Git:
    """Runs git in one repository. `env` replaces the environment wholesale (the tests use it to
    keep the user's global configuration out); None inherits this process's."""

    def __init__(self, cwd: str, env: dict[str, str] | None = None):
        self.cwd = cwd
        self.env = env

    def run(self, *args: str, check: bool = True,
            extra_env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
        env = dict(os.environ if self.env is None else self.env)
        env.update(extra_env or {})
        proc = subprocess.run(("git",) + args, cwd=self.cwd, env=env, capture_output=True,
                              text=True, encoding="utf-8", errors="surrogateescape")
        if check and proc.returncode != 0:
            raise GitError(args, proc)
        return proc

    def out(self, *args: str) -> str:
        return self.run(*args).stdout


@dataclass
class Commit:
    sha: str
    date: str
    subject: str
    paths: list[str]


@dataclass
class Simulation:
    conflicts: list[str] = field(default_factory=list)
    removed: list[str] = field(default_factory=list)

    def describe(self) -> str:
        if self.conflicts:
            return f"{len(self.conflicts)} conflict" + ("" if len(self.conflicts) == 1 else "s")
        return f"clean, {len(self.removed)} rm" if self.removed else "clean"


@dataclass
class Row:
    commit: Commit
    paths: list[str]
    hidden: str = ""
    reason: str = ""
    sim: Simulation | None = None
    # The earlier candidates this one applies cleanly on top of, when it conflicts against HEAD
    # alone: a fix that builds on an earlier upstream commit (a follow-up to it, or a later edit to
    # the same lines) cannot apply until that one is in. Empty when it applies without them, or
    # conflicts with them too.
    after: list[str] = field(default_factory=list)

    @property
    def areas(self) -> list[str]:
        return areas_of(self.paths)

    @property
    def names_removed_scope(self) -> bool:
        return REMOVED_SCOPE.search(self.commit.subject) is not None


def area_of(path: str) -> str:
    parts = path.split("/")
    if len(parts) > 2 and parts[0] == "Packages" and parts[2] == "Tests":
        return "tests"
    if len(parts) == 1 and path.endswith(".md"):
        return "docs"
    for prefix, area in AREA_PREFIXES:
        if path.startswith(prefix):
            return area
    return "other"


def areas_of(paths: list[str], keep_tests: bool = False) -> list[str]:
    """The areas a commit touches, in AREA_ORDER. Tests and docs are left out beside code unless
    `keep_tests`: nearly every fix carries a test, and the tag should say what the fix is to."""
    found = {area_of(p) for p in paths}
    if not keep_tests and found - {"tests", "docs"}:
        found -= {"tests", "docs"}
    return [a for a in AREA_ORDER if a in found]


def area_tag(areas: list[str], most: int = 3) -> str:
    """The AREA column: the first `most` areas, then how many more, so a sweeping commit cannot
    push the subjects out of line."""
    if not areas:
        return "-"
    extra = len(areas) - most
    return ",".join(areas[:most]) + (f"+{extra}" if extra > 0 else "")


def _dirs(paths) -> set[str]:
    dirs: set[str] = set()
    for path in paths:
        if path:
            dirs.update(str(p) for p in PurePosixPath(path).parents if str(p) != ".")
    return dirs


@dataclass
class Removed:
    """What this fork deleted since the merge-base: files, and the directories that went with them.
    `path in removed` asks whether a path lies in either."""
    files: set[str] = field(default_factory=set)
    dirs: set[str] = field(default_factory=set)

    def __contains__(self, path: str) -> bool:
        return path in self.files or any(str(p) in self.dirs for p in PurePosixPath(path).parents)


def removed_paths(git: Git, base: str, head: str) -> Removed:
    """Files this fork deleted since `base`, and the directories that went with them.

    A deleted file is a `D` in a rename-detecting diff, so a file the fork only moved is not in the
    set and upstream's edits to it still count. A directory is gone when it held a deleted file and
    no longer exists at `head`: that is what makes a NEW upstream file under android/ irrelevant,
    while a new file in a directory the fork kept, or in a brand-new one, stays a candidate.
    """
    fields = git.out("diff", "--name-status", "-z", "--find-renames", base, head).split("\0")
    files: set[str] = set()
    i = 0
    while i < len(fields) and fields[i]:
        status = fields[i]
        if status[0] in "RC":  # renames and copies carry two paths
            i += 3
            continue
        if status == "D":
            files.add(fields[i + 1])
        i += 2
    kept_dirs = _dirs(git.out("ls-tree", "-r", "--name-only", "-z", head).split("\0"))
    return Removed(files, _dirs(files) - kept_dirs)


def upstream_commits(git: Git, head: str, upstream: str) -> list[Commit]:
    """Upstream's non-merge commits that `head` does not contain, oldest first, each with every path
    it touches. Both sides of a rename are listed, so an edit to a file this fork kept is never lost
    behind a new name."""
    out = git.out("log", "--no-merges", "--reverse", "--no-renames", "--name-only", "-z",
                  "--format=%x01%H%x00%cs%x00%s", f"{head}..{upstream}")
    commits = []
    for chunk in out.split("\x01")[1:]:
        fields = chunk.split("\0")
        paths = [f.lstrip("\n") for f in fields[3:]]
        commits.append(Commit(fields[0], fields[1], fields[2], [p for p in paths if p]))
    return commits


def picked(git: Git, head: str, upstream: str) -> set[str]:
    """Upstream commits this branch has taken with `cherry-pick -x`."""
    return set(PICKED_TRAILER.findall(git.out("log", "--format=%B", f"{upstream}..{head}")))


def same_patch(git: Git, head: str, upstream: str) -> set[str]:
    """Upstream commits whose patch id matches a commit on this branch: a pick made without -x."""
    out = git.out("cherry", head, upstream)
    return {line[2:].strip() for line in out.splitlines() if line.startswith("- ")}


@dataclass
class Skips:
    shas: dict[str, str] = field(default_factory=dict)
    subjects: list[tuple[re.Pattern[str], str]] = field(default_factory=list)

    def reason(self, commit: Commit) -> str | None:
        for prefix, reason in self.shas.items():
            if commit.sha.startswith(prefix):
                return reason or "(no reason given)"
        for pattern, reason in self.subjects:
            if pattern.search(commit.subject):
                return reason or "(no reason given)"
        return None


def load_skips(text: str, source: str = SKIP_FILE) -> Skips:
    """Parse the skip ledger. Each line is one of

        <sha> <reason>        one commit; the SHA may be abbreviated to 7 or more hex digits
        /<regex>/ <reason>    every commit whose subject the regex matches; the regex ends at
                              the first `/` followed by a space or the end of the line

    A line starting with `#` is a comment. A `#` later in a line is part of the reason, which
    usually cites an issue."""
    skips = Skips()
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        pattern = re.match(r"/(.+?)/(?:\s+(.*))?$", line)
        if pattern:
            try:
                skips.subjects.append((re.compile(pattern.group(1)), (pattern.group(2) or "").strip()))
            except re.error as err:
                raise ValueError(f"{source}:{n}: bad subject pattern: {err}") from None
            continue
        sha, _, reason = line.partition(" ")
        if not re.fullmatch(r"[0-9a-f]{7,40}", sha):
            raise ValueError(f"{source}:{n}: expected '<sha> <reason>' or '/<regex>/ <reason>', "
                             f"got {raw!r}")
        skips.shas[sha] = reason.strip()
    return skips


def parse_merge_tree(out: str, removed: Container[str]) -> Simulation:
    """Split `git merge-tree --write-tree -z --no-messages` output into real conflicts and files
    this fork removed.

    The output is the result tree, then one `<mode> <oid> <stage>\\t<path>` entry per conflicted
    stage. Stage 1 is the picked commit's parent, 2 is HEAD and 3 is the picked commit, so a path
    with stages 1 and 3 but no 2 is missing here and edited upstream. Only when this fork REMOVED
    it is deleting it again the whole resolution. The same shape also means the file does not
    exist here YET, added by an earlier upstream commit this fork has not taken; dropping it then
    would silently cut part of the fix, so it is a conflict like every other shape (both sides
    edited, upstream deleted what the fork edited, both added).
    """
    stages: dict[str, set[int]] = {}
    for entry in out.split("\0")[1:]:
        if not entry:
            continue
        meta, _, path = entry.partition("\t")
        stages.setdefault(path, set()).add(int(meta.split()[2]))
    dropped = sorted(p for p, s in stages.items() if s == {1, 3} and p in removed)
    return Simulation(sorted(p for p in stages if p not in dropped), dropped)


def _merge_tree(git: Git, sha: str, onto: str) -> subprocess.CompletedProcess:
    proc = git.run("merge-tree", "--write-tree", "-z", "--no-messages", f"--merge-base={sha}^",
                   onto, sha, check=False)
    if proc.returncode not in (0, 1):  # 1 means conflicts; anything else is an error
        raise GitError(("merge-tree", sha), proc)
    return proc


def simulate(git: Git, sha: str, head: str, removed: Container[str]) -> Simulation:
    """What `git cherry-pick sha` onto `head` would do, without touching the index or work tree."""
    return parse_merge_tree(_merge_tree(git, sha, head).stdout, removed)


# Identity for the throwaway commits simulate_after chains through, so it works whatever the
# user's configuration holds. Nothing points at those commits; `git gc` collects them.
_SIM_IDENTITY = {"GIT_AUTHOR_NAME": "upstream-candidates", "GIT_AUTHOR_EMAIL": "sim@invalid",
                 "GIT_COMMITTER_NAME": "upstream-candidates", "GIT_COMMITTER_EMAIL": "sim@invalid"}


def simulate_after(git: Git, sha: str, earlier: list[str], head: str,
                   removed: Container[str]) -> tuple[Simulation, list[str]]:
    """Simulate picking `sha` on top of `head` plus each of `earlier` that applies cleanly in turn;
    returns the result and the ones it went through. A link that needs a hand resolution itself is
    left out rather than ending the chain.

    Each step's result tree becomes a throwaway commit the next merge-tree starts from. A file this
    fork removed comes back into that tree when an earlier link edits it ("left in tree"), so a
    conflict on such a path later in the chain is still not a real one."""
    onto, used = head, []
    for step in earlier + [sha]:
        proc = _merge_tree(git, step, onto)
        sim = parse_merge_tree(proc.stdout, removed)
        real = [p for p in sim.conflicts if p not in removed]
        if step == sha:
            return Simulation(real, sorted(set(sim.removed) | set(sim.conflicts) - set(real))), used
        if real:
            continue
        tree = proc.stdout.split("\0", 1)[0]
        onto = git.run("commit-tree", "--no-gpg-sign", tree, "-p", onto, "-m", "simulation",
                       extra_env=_SIM_IDENTITY).stdout.strip()
        used.append(step)
    raise AssertionError("unreachable: the loop returns at `sha`")


def collect(git: Git, head: str, upstream: str, skips: Skips) -> list[Row]:
    base = git.out("merge-base", head, upstream).strip()
    removed = removed_paths(git, base, head)
    taken = picked(git, head, upstream)
    same = same_patch(git, head, upstream)
    rows = []
    for commit in upstream_commits(git, head, upstream):
        row = Row(commit, [p for p in commit.paths if p not in removed])
        reason = skips.reason(commit)
        if commit.sha in taken:
            row.hidden = "picked"
        elif commit.sha in same:
            row.hidden = "same patch"
        elif reason is not None:
            row.hidden, row.reason = "skipped", reason
        elif not row.paths:
            row.hidden = "removed only"
        else:
            row.sim = simulate(git, commit.sha, head, removed)
            conflicted = set(row.sim.conflicts)
            earlier = [r.commit.sha for r in rows if not r.hidden and conflicted & set(r.paths)]
            if earlier:
                chained, used = simulate_after(git, commit.sha, earlier, head, removed)
                if used and not chained.conflicts:
                    row.sim, row.after = chained, used
        rows.append(row)
    return rows


def render(rows: list[Row], title: str, show_all: bool, verbose: bool) -> str:
    counts = {k: sum(1 for r in rows if r.hidden == k)
              for k in ("removed only", "picked", "same patch", "skipped")}
    lines = [title,
             f"hidden: {counts['removed only']} only touch code this fork removed · "
             f"{counts['picked']} picked with -x · {counts['same patch']} same patch already here · "
             f"{counts['skipped']} in {SKIP_FILE}" + ("" if show_all else "  (--all lists them)"),
             ""]
    shown = [r for r in rows if show_all or not r.hidden]
    if not shown:
        lines.append("Nothing new to decide about.")
        return "\n".join(lines)
    tags = {id(r): area_tag(r.areas) for r in shown}
    area_w = max(4, max(len(t) for t in tags.values()))
    lines.append(f"  {'SHA':8}  {'DATE':10}  {'AREA':{area_w}}  {'APPLIES':13}  SUBJECT")
    for r in shown:
        flag = "~" if r.names_removed_scope else " "
        applies = (r.sim.describe() + (" ^" if r.after else "")) if r.sim else r.hidden
        area = tags[id(r)]
        lines.append(f"{flag} {r.commit.sha[:8]}  {r.commit.date:10}  {area:{area_w}}  "
                     f"{applies:13}  {r.commit.subject}")
        if verbose:
            if r.reason:
                lines.append(f"      skipped: {r.reason}")
            if r.after:
                lines.append(f"      after     {' '.join(s[:8] for s in r.after)}")
            for path in r.paths:
                mark = "conflict" if r.sim and path in r.sim.conflicts else "touches "
                lines.append(f"      {mark}  {path}")
            if r.sim:
                for path in r.sim.conflicts:
                    if path not in r.paths:
                        lines.append(f"      conflict  {path}")
                if r.sim.removed:
                    lines.append(f"      drops     {len(r.sim.removed)} file(s) this fork removed")
    lines += ["",
              "clean: applies as it is · clean, N rm: also edits N files this fork removed, which "
              "--apply drops · N conflicts: pick by hand (-v names the files)",
              "^ applies only on top of earlier commits in this list: give --apply those too "
              "(-v names them)",
              "~ the subject names a device or platform this fork removed: check the commit is not "
              "only for that",
              f"take:  Tools/upstream-candidates.py --apply <sha>...    decline:  add '<sha> <reason>' "
              f"to {SKIP_FILE}"]
    return "\n".join(lines)


def unmerged_paths(git: Git) -> dict[str, str]:
    """Paths `git status` reports as unmerged, with their two-letter state (DU = deleted by us)."""
    fields = git.out("status", "--porcelain=v1", "-z", "--untracked-files=no").split("\0")
    result: dict[str, str] = {}
    i = 0
    while i < len(fields) and fields[i]:
        entry = fields[i]
        xy, path = entry[:2], entry[3:]
        i += 2 if xy[0] in "RC" else 1
        if "U" in xy or xy in ("AA", "DD"):
            result[path] = xy
    return result


def _in_progress(git: Git) -> str | None:
    for name in ("CHERRY_PICK_HEAD", "MERGE_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply",
                 "sequencer"):
        if os.path.exists(os.path.join(git.cwd, git.out("rev-parse", "--git-path", name).strip())):
            return name
    return None


def apply(git: Git, shas: list[str], upstream: str, allow_main: bool, out: TextIO) -> int:
    """Pick `shas` in upstream order with -x. Returns 0 when every one landed, 1 when it stopped
    before a commit that needs a hand resolution (the tree is left clean), 2 on a refusal."""
    if git.run("diff", "--quiet", "HEAD", check=False).returncode != 0:
        print("refusing: tracked files have changes; commit or stash them first", file=out)
        return 2
    busy = _in_progress(git)
    if busy:
        print(f"refusing: an operation is already in progress ({busy})", file=out)
        return 2
    branch = git.run("symbolic-ref", "--short", "-q", "HEAD", check=False).stdout.strip()
    if branch == "main" and not allow_main:
        print("refusing to commit picks straight onto main (--allow-main overrides); branch first:\n"
              "    git switch -c upstream-picks", file=out)
        return 2

    removed = removed_paths(git, git.out("merge-base", "HEAD", upstream).strip(), "HEAD")
    pending = upstream_commits(git, "HEAD", upstream)
    order = [c.sha for c in pending]
    subjects = {c.sha: c.subject for c in pending}
    taken = picked(git, "HEAD", upstream) | same_patch(git, "HEAD", upstream)
    wanted = []
    for sha in shas:
        full = git.run("rev-parse", "--verify", "--quiet", f"{sha}^{{commit}}",
                       check=False).stdout.strip()
        if not full:
            print(f"refusing: {sha} is not a commit here (try --fetch)", file=out)
            return 2
        if full not in order:
            print(f"refusing: {sha} is not an upstream commit missing from HEAD", file=out)
            return 2
        if full in taken:
            print(f"already here: {full[:8]} {subjects[full]}", file=out)
        elif full not in wanted:
            wanted.append(full)
    wanted.sort(key=order.index)

    for i, sha in enumerate(wanted):
        short, subject = sha[:8], subjects[sha]
        sim = simulate(git, sha, "HEAD", removed)
        if sim.conflicts:
            rest = " ".join(s[:8] for s in wanted[i + 1:])
            print(f"stopped before {short} ({subject}): it conflicts in", file=out)
            for path in sim.conflicts:
                print(f"    {path}", file=out)
            print(f"  pick it by hand:  git cherry-pick -x {short}\n"
                  f"                    git rm the files this fork removed, resolve the rest, "
                  f"git cherry-pick --continue", file=out)
            if rest:
                print(f"  then resume:      Tools/upstream-candidates.py --apply {rest}", file=out)
            return 1
        proc = git.run("cherry-pick", "-x", sha, check=False)
        if proc.returncode != 0:
            if _in_progress(git) != "CHERRY_PICK_HEAD":
                print(f"stopped at {short}: git refused the pick:\n{proc.stderr.strip()}", file=out)
                return 1
            unmerged = unmerged_paths(git)
            unexpected = sorted(p for p, xy in unmerged.items() if xy != "DU" or p not in removed)
            if unexpected:
                print(f"stopped in the middle of {short}: conflicts the simulation did not "
                      f"predict: {', '.join(unexpected)}\n  resolve them, then git cherry-pick "
                      f"--continue (or --abort)", file=out)
                return 1
            if unmerged:
                git.run("rm", "--quiet", "--", *sorted(unmerged))
            if git.run("diff", "--cached", "--quiet", "HEAD", check=False).returncode == 0:
                git.run("cherry-pick", "--skip")
                print(f"skipped {short}: it changes nothing here (already present, or it only "
                      f"edits files this fork removed; worth a line in {SKIP_FILE})", file=out)
                continue
            git.run("cherry-pick", "--continue", extra_env={"GIT_EDITOR": "true"})
        dropped = f"  (dropped {len(sim.removed)} removed file(s))" if sim.removed else ""
        print(f"picked {short} -> {git.out('rev-parse', '--short', 'HEAD').strip()}  "
              f"{subject}{dropped}", file=out)
    if wanted:
        print("done. swift-packages.yml does not compile the apps; app-build.yml does, on a PR "
              "that touches Strand/, StrandTests/ or StrandiOS*/ (or build locally).", file=out)
    return 0


def git_version(git: Git) -> tuple[int, int]:
    match = re.search(r"(\d+)\.(\d+)", git.out("version"))
    return (int(match.group(1)), int(match.group(2))) if match else (0, 0)


def main(argv: list[str] | None = None, git: Git | None = None) -> int:
    ap = argparse.ArgumentParser(
        description="List the upstream commits this fork has not taken, and which apply cleanly.",
        epilog="Areas: " + ", ".join(AREA_ORDER))
    ap.add_argument("--upstream", default=DEFAULT_UPSTREAM,
                    help=f"the upstream ref to compare against (default {DEFAULT_UPSTREAM})")
    ap.add_argument("--fetch", action="store_true", help="git fetch the upstream's remote first")
    ap.add_argument("--area", help="only commits touching these comma-separated areas")
    ap.add_argument("--all", action="store_true", help="also list hidden commits, with the reason")
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="list each commit's files, its conflicts and skip reasons")
    ap.add_argument("--skip-file", help=f"the skip ledger (default {SKIP_FILE} in the repository)")
    ap.add_argument("--apply", nargs="+", metavar="SHA", help="cherry-pick these, in upstream order")
    ap.add_argument("--allow-main", action="store_true", help="let --apply commit onto main")
    args = ap.parse_args(argv)

    if git is None:
        top = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True)
        if top.returncode != 0:
            print("not inside a git repository", file=sys.stderr)
            return 2
        git = Git(top.stdout.strip())
    if git_version(git) < MIN_GIT:
        print(f"needs git {MIN_GIT[0]}.{MIN_GIT[1]} or later (merge-tree --merge-base)",
              file=sys.stderr)
        return 2
    if args.fetch:
        git.run("fetch", "--quiet", args.upstream.split("/", 1)[0])
    if git.run("rev-parse", "--verify", "--quiet", f"{args.upstream}^{{commit}}",
               check=False).returncode != 0:
        print(f"no ref {args.upstream}. Add and fetch it first:\n"
              f"    git remote add upstream https://github.com/ryanbr/noop.git && git fetch upstream",
              file=sys.stderr)
        return 2

    if args.apply:
        return apply(git, args.apply, args.upstream, args.allow_main, sys.stdout)

    skip_path = Path(args.skip_file) if args.skip_file else Path(git.cwd) / SKIP_FILE
    skips = load_skips(skip_path.read_text(encoding="utf-8"), str(skip_path)) \
        if skip_path.exists() else Skips()
    rows = collect(git, "HEAD", args.upstream, skips)
    if args.area:
        wanted = {a.strip() for a in args.area.split(",") if a.strip()}
        unknown = wanted - set(AREA_ORDER)
        if unknown:
            print(f"unknown area(s): {', '.join(sorted(unknown))}; known: {', '.join(AREA_ORDER)}",
                  file=sys.stderr)
            return 2
        rows = [r for r in rows if wanted & set(areas_of(r.paths, keep_tests=True))]

    tip = git.out("log", "-1", "--format=%h %cs", args.upstream).split()
    head = git.out("rev-parse", "--short", "HEAD").strip()
    shown = sum(1 for r in rows if not r.hidden)
    title = (f"{args.upstream} {tip[0]} ({tip[1]}) vs HEAD {head}: {len(rows)} upstream commits "
             f"not here, {shown} to decide about" + (f" (areas: {args.area})" if args.area else ""))
    print(render(rows, title, args.all, args.verbose))
    return 0


if __name__ == "__main__":
    sys.exit(main())
