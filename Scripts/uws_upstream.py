#!/usr/bin/env python3
"""Review upstream references; never install or execute Usage Window Starter."""

import argparse
import datetime
import difflib
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tempfile
import uuid


REPOSITORY = "https://github.com/foksa/usage-window-starter"
REFERENCE_ROOTS = ["LICENSE", "src/go/core/"]
LOCK_NAME = "UsageWindowStarter.lock.json"


class ReviewError(Exception):
    """An unsafe, incomplete, or stale update was refused."""


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def json_bytes(value):
    return (json.dumps(value, indent=2, sort_keys=True) + "\n").encode()


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def atomic_write(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


class UpstreamReview:
    def __init__(self, repo_root, cache_dir, repository=REPOSITORY):
        self.root = Path(repo_root).resolve()
        self.cache = Path(cache_dir).resolve()
        if self.cache == self.root or self.root in self.cache.parents:
            raise ReviewError("The Git cache must be outside the application repository")
        self.repository = repository
        self.git_dir = self.cache / "repository.git"
        self.lock_path = self.root / "Upstream" / LOCK_NAME

    def git(self, *args):
        result = subprocess.run(
            ["git", "--no-replace-objects", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
             "--git-dir=" + str(self.git_dir), *args],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )
        if result.returncode:
            raise ReviewError("Git failed: " + result.stderr.decode(errors="replace").strip())
        return result.stdout

    def ensure_cache(self):
        if not self.git_dir.exists():
            self.cache.mkdir(parents=True, exist_ok=True)
            result = subprocess.run(
                ["git", "-c", "core.hooksPath=/dev/null", "init", "--bare", str(self.git_dir)],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
            )
            if result.returncode:
                raise ReviewError("Cannot initialize the isolated Git cache")
        if self.git("rev-parse", "--is-bare-repository").strip() != b"true":
            raise ReviewError("The upstream cache must be a bare Git repository")

    def fetch_tag(self, tag):
        # Fetch into a private fresh ref so an annotated tag is always peeled.
        if not isinstance(tag, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]*", tag):
            raise ReviewError("An explicit valid upstream tag is required")
        ref = "refs/tags/" + tag
        self.ensure_cache()
        self.git("check-ref-format", ref)
        destination = "refs/uws-review/" + uuid.uuid4().hex
        self.git("fetch", "--no-tags", "--", self.repository, ref + ":" + destination)
        return self.git("rev-parse", destination + "^{commit}").decode().strip()

    @staticmethod
    def validate_lock(lock, repository):
        if (not isinstance(lock, dict) or lock.get("schemaVersion") != 1 or lock.get("repository") != repository
                or lock.get("referenceRoots") != REFERENCE_ROOTS
                or not re.fullmatch(r"[0-9a-f]{40}", lock.get("commit", ""))
                or not lock.get("tag") or not lock.get("adaptationRevision")
                or not lock.get("reviewDate")):
            raise ReviewError("Invalid upstream lock metadata")
        files = lock.get("files")
        if not isinstance(files, dict) or "LICENSE" not in files or "src/go/core/codex.go" not in files:
            raise ReviewError("The lock is missing required reference files")
        for path, digest in files.items():
            if (not isinstance(path, str) or PurePosixPath(path).is_absolute()
                    or ".." in PurePosixPath(path).parts
                    or not (path == "LICENSE" or path.startswith("src/go/core/"))
                    or not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest)):
                raise ReviewError("Invalid reference file or SHA-256 in lock")

    def load_lock(self):
        raw = self.lock_path.read_bytes()
        lock = json.loads(raw)
        self.validate_lock(lock, self.repository)
        return lock, raw

    def snapshot(self, commit):
        if not re.fullmatch(r"[0-9a-f]{40}", commit):
            raise ReviewError("Expected a full peeled commit SHA")
        listing = self.git("ls-tree", "-r", "-z", commit, "--", *REFERENCE_ROOTS)
        files = {}
        for entry in listing.split(b"\0"):
            if not entry:
                continue
            metadata, raw_path = entry.split(b"\t", 1)
            mode, kind, object_id = metadata.split()
            path = raw_path.decode("utf-8")
            if mode not in (b"100644", b"100755") or kind != b"blob":
                raise ReviewError("Reference files must be ordinary Git blobs: " + path)
            files[path] = self.git("cat-file", "blob", object_id.decode())
        if "LICENSE" not in files or "src/go/core/codex.go" not in files:
            raise ReviewError("Upstream is missing the license or Codex implementation")
        license_text = files["LICENSE"].decode("utf-8")
        if (not license_text.startswith("MIT License")
                or "Permission is hereby granted, free of charge" not in license_text
                or "The above copyright notice" not in license_text):
            raise ReviewError("Upstream licensing changed; review it outside this MIT workflow")
        return files

    def verify_snapshot(self, lock):
        files = self.snapshot(lock["commit"])
        actual = {path: sha256(data) for path, data in files.items()}
        if actual != lock["files"]:
            raise ReviewError("Reference inventory or content does not match the locked SHA-256 values")
        return files

    def verify(self):
        lock, _ = self.load_lock()
        if not self.git_dir.exists():
            raise ReviewError("Offline cache is missing; run prepare with the pinned tag to populate it")
        files = self.verify_snapshot(lock)
        license_path = self.root / "Upstream" / "LICENSE.UsageWindowStarter"
        if not license_path.exists() or license_path.read_bytes() != files["LICENSE"]:
            raise ReviewError("The preserved upstream MIT notice differs from the locked license")
        return lock

    def prepare(self, tag, output_dir):
        lock, raw = self.load_lock()
        # Verify the old tag before trusting a new comparison baseline.
        if self.fetch_tag(lock["tag"]) != lock["commit"]:
            raise ReviewError("The pinned upstream tag moved; the current lock was preserved")
        old = self.verify_snapshot(lock)
        commit = self.fetch_tag(tag)
        if tag == lock["tag"] and commit != lock["commit"]:
            raise ReviewError("The pinned upstream tag moved")
        new = self.snapshot(commit)
        paths = sorted(set(old) | set(new))
        changed = [path for path in paths if old.get(path) != new.get(path)]
        candidate = {
            "schemaVersion": 1, "repository": self.repository, "tag": tag, "commit": commit,
            "referenceRoots": REFERENCE_ROOTS,
            "files": {path: sha256(data) for path, data in sorted(new.items())},
            "baselineLockSHA256": sha256(raw), "preparedAt": utc_now(),
        }
        lines = ["# Usage Window Starter upstream review", "",
                 "Candidate manifest SHA-256: `" + sha256(json_bytes(candidate)) + "`", "",
                 "Repository: " + self.repository, "",
                 "Baseline: `" + lock["tag"] + "` / `" + lock["commit"] + "`", "",
                 "Candidate: `" + tag + "` / `" + commit + "`", "",
                 "Baseline lock SHA-256: `" + sha256(raw) + "`", "",
                 "This report is reference material, not a Swift implementation update.", "",
                 "Review Codex parsing, idle detection, scheduler timing, state protection, transport,",
                 "tests, new/deleted core files, and licensing. Adapt native Swift before acceptance.", "",
                 "Changed reference files: " + str(len(changed)), ""]
        for path in changed:
            status = "added" if path not in old else "deleted" if path not in new else "modified"
            lines.extend(["## " + path + " (" + status + ")", "",
                          "Old SHA-256: `" + (sha256(old[path]) if path in old else "absent") + "`", "",
                          "New SHA-256: `" + (sha256(new[path]) if path in new else "absent") + "`", ""])
            # Indent diff lines instead of a fixed fence: upstream may contain fences.
            diff = difflib.unified_diff(
                old.get(path, b"").decode("utf-8", errors="replace").splitlines(),
                new.get(path, b"").decode("utf-8", errors="replace").splitlines(),
                fromfile="a/" + path, tofile="b/" + path, lineterm="",
            )
            lines.extend("    " + line for line in diff)
            lines.append("")
        report = ("\n".join(lines) + "\n").encode()
        candidate["reportSHA256"] = sha256(report)
        output_dir = Path(output_dir).resolve()
        if output_dir == self.lock_path.parent or self.lock_path.parent in output_dir.parents:
            raise ReviewError("Review outputs must be outside the accepted Upstream directory")
        output_dir.mkdir(parents=True, exist_ok=True)
        candidate_path = output_dir / "candidate.json"
        report_path = output_dir / "review.md"
        if candidate_path.exists() or report_path.exists():
            raise ReviewError("Review output already exists; use a new output directory")
        atomic_write(report_path, report)
        atomic_write(candidate_path, json_bytes(candidate))
        return candidate_path

    def run_swift_tests(self):
        result = subprocess.run(
            ["swift", "test"], cwd=self.root, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, check=False,
        )
        # Keep complete evidence outside the source tree; a nonzero exit cannot update the lock.
        log_path = self.cache / ("swift-test-" + uuid.uuid4().hex + ".log")
        atomic_write(log_path, result.stdout)
        if result.returncode:
            raise ReviewError("swift test failed; lock unchanged. Evidence: " + str(log_path))
        output = result.stdout.decode(errors="replace")
        if not (re.search(r"Executed [1-9][0-9]* tests?, with 0 failures", output)
                or re.search(r"Test run with [1-9][0-9]* tests? .*passed", output)):
            raise ReviewError("No passing Swift test suite was recorded; lock unchanged. Evidence: " + str(log_path))
        return {"command": "swift test", "exitCode": 0,
                "outputSHA256": sha256(result.stdout), "completedAt": utc_now()}

    def accept(self, candidate_path, revision, note):
        if not revision or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", revision):
            raise ReviewError("An explicit adaptation revision is required")
        if len(note.strip()) < 20:
            raise ReviewError("Provide a concrete review note of at least 20 characters")
        candidate_path = Path(candidate_path).resolve()
        candidate_raw = candidate_path.read_bytes()
        candidate = json.loads(candidate_raw)
        lock, baseline_raw = self.load_lock()
        validation = dict(candidate, adaptationRevision=revision, reviewDate=utc_now())
        self.validate_lock(validation, self.repository)
        if revision == lock["adaptationRevision"]:
            raise ReviewError("Acceptance requires a new native adaptation revision")
        if candidate.get("baselineLockSHA256") != sha256(baseline_raw):
            raise ReviewError("Stale candidate: the accepted baseline changed")
        report_path = candidate_path.parent / "review.md"
        report = report_path.read_bytes()
        manifest = {key: value for key, value in candidate.items() if key != "reportSHA256"}
        binding = ("Candidate manifest SHA-256: `" + sha256(json_bytes(manifest)) + "`").encode()
        if binding not in report or sha256(report) != candidate.get("reportSHA256"):
            raise ReviewError("The review report was modified after preparation")
        if self.fetch_tag(lock["tag"]) != lock["commit"]:
            raise ReviewError("The pinned baseline tag moved")
        if self.fetch_tag(candidate["tag"]) != candidate["commit"]:
            raise ReviewError("The candidate tag moved after preparation")
        self.verify_snapshot(lock)
        new = self.verify_snapshot(candidate)
        evidence = self.run_swift_tests()
        # Detect concurrent preparation/acceptance or editing while verification ran.
        if (self.lock_path.read_bytes() != baseline_raw
                or candidate_path.read_bytes() != candidate_raw
                or sha256(report_path.read_bytes()) != candidate["reportSHA256"]):
            raise ReviewError("Review inputs changed during verification; lock unchanged")
        # Re-fetch after the test run so tag movement during verification is refused too.
        if self.fetch_tag(candidate["tag"]) != candidate["commit"]:
            raise ReviewError("The candidate tag moved during verification")
        if self.lock_path.read_bytes() != baseline_raw:
            raise ReviewError("The accepted baseline changed during the final tag check")
        accepted = {key: candidate[key] for key in
                    ("schemaVersion", "repository", "tag", "commit", "referenceRoots", "files")}
        accepted.update(adaptationRevision=revision, reviewDate=utc_now(),
                        reviewNote=note.strip(), verification=evidence,
                        reviewReportSHA256=candidate["reportSHA256"])
        atomic_write(self.root / "Upstream" / "LICENSE.UsageWindowStarter", new["LICENSE"])
        atomic_write(self.lock_path, json_bytes(accepted))
        return accepted


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--cache-dir", type=Path,
                        default=Path.home() / "Library/Caches/CodexMeter/UWSUpstream")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("verify", help="Verify the current lock and Git objects without network access")
    prepare = commands.add_parser("prepare", help="Fetch an explicit tag and produce a review candidate")
    prepare.add_argument("--tag", required=True)
    prepare.add_argument("--output-dir", type=Path, required=True)
    accept = commands.add_parser("accept", help="Review attestation + real swift test before lock update")
    accept.add_argument("--candidate", type=Path, required=True)
    accept.add_argument("--adaptation-revision", required=True)
    accept.add_argument("--review-note", required=True)
    args = parser.parse_args(argv)
    try:
        workflow = UpstreamReview(args.repo_root, args.cache_dir)
        if args.command == "verify":
            lock = workflow.verify()
            print("Verified " + lock["tag"] + " @ " + lock["commit"] + " (offline)")
        elif args.command == "prepare":
            print(workflow.prepare(args.tag, args.output_dir))
        else:
            lock = workflow.accept(args.candidate, args.adaptation_revision, args.review_note)
            print("Accepted " + lock["tag"] + " @ " + lock["commit"])
    except (ReviewError, OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, "error: " + str(error) + "\n")


if __name__ == "__main__":
    main()
