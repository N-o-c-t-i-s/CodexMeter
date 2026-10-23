import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


MODULE_PATH = Path(__file__).resolve().parents[1] / "uws_upstream.py"
SPEC = importlib.util.spec_from_file_location("uws_upstream", MODULE_PATH)
uws = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(uws)

LICENSE = b"MIT License\nCopyright (c) Example\nPermission is hereby granted, free of charge\nThe above copyright notice\n"


class UpstreamReviewTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.source = self.base / "source"
        self.source.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        (self.source / "src/go/core").mkdir(parents=True)
        (self.source / "LICENSE").write_bytes(LICENSE)
        (self.source / "src/go/core/codex.go").write_text("baseline\n")
        (self.source / "src/go/core/exec.go").write_text("old execution\n")
        self.commit("Baseline")
        self.first = self.git("rev-parse", "HEAD").strip()
        self.git("tag", "v0.4.0")
        self.root = self.base / "app"
        (self.root / "Upstream").mkdir(parents=True)
        self.workflow = uws.UpstreamReview(self.root, self.base / "cache", str(self.source))
        self.workflow.fetch_tag("v0.4.0")
        snapshot = self.workflow.snapshot(self.first)
        self.lock = dict(schemaVersion=1, repository=str(self.source), tag="v0.4.0",
                         commit=self.first, referenceRoots=uws.REFERENCE_ROOTS,
                         files={path: uws.sha256(data) for path, data in snapshot.items()},
                         adaptationRevision="native-v1", reviewDate="2026-10-23")
        self.workflow.lock_path.write_bytes(uws.json_bytes(self.lock))
        (self.root / "Upstream/LICENSE.UsageWindowStarter").write_bytes(LICENSE)
        self.initial_lock = self.workflow.lock_path.read_bytes()
        (self.source / "src/go/core/codex.go").write_text("new parser\n")
        (self.source / "src/go/core/exec.go").unlink()
        (self.source / "src/go/core/new_test.go").write_text("new regression\n")
        self.commit("New behavior")
        self.second = self.git("rev-parse", "HEAD").strip()
        self.git("tag", "-a", "v0.5.0", "-m", "Annotated release")
        self.output = self.base / "review"

    def git(self, *args):
        return subprocess.check_output(
            ["git", "-c", "core.hooksPath=/dev/null", "-C", str(self.source), *args],
            stderr=subprocess.PIPE,
        ).decode()

    def commit(self, message):
        self.git("add", ".")
        self.git("commit", "-q", "-m", message)

    def prepare(self):
        return self.workflow.prepare("v0.5.0", self.output)

    def accept(self, candidate):
        return self.workflow.accept(candidate, "native-v2", "Reviewed parser, scheduler, and Swift regressions.")

    def assert_lock_unchanged(self):
        self.assertEqual(self.workflow.lock_path.read_bytes(), self.initial_lock)

    def test_verify_is_offline_and_checks_inventory_and_license(self):
        with patch.object(self.workflow, "fetch_tag", side_effect=AssertionError("No network")):
            self.assertEqual(self.workflow.verify()["commit"], self.first)

    def test_prepare_peels_annotated_tag_and_preserves_lock(self):
        candidate = json.loads(self.prepare().read_text())
        self.assertEqual(candidate["commit"], self.second)
        self.assertNotEqual(self.git("rev-parse", "v0.5.0").strip(), self.second)
        report = (self.output / "review.md").read_text()
        self.assertIn("exec.go (deleted)", report)
        self.assertIn("new_test.go (added)", report)
        self.assertIn("codex.go (modified)", report)
        self.assert_lock_unchanged()

    def test_explicit_pinned_tag_populates_cache_without_update(self):
        candidate = self.workflow.prepare("v0.4.0", self.output)
        self.assertEqual(json.loads(candidate.read_text())["commit"], self.first)
        self.assertIn("Changed reference files: 0", (self.output / "review.md").read_text())
        self.assert_lock_unchanged()

    def test_prepare_refuses_moved_baseline_tag(self):
        self.git("tag", "-f", "v0.4.0", self.second)
        with self.assertRaisesRegex(uws.ReviewError, "tag moved"):
            self.prepare()
        self.assert_lock_unchanged()

    def test_accept_refuses_tag_moved_after_preparation(self):
        candidate = self.prepare()
        self.git("tag", "-f", "v0.5.0", self.first)
        with self.assertRaisesRegex(uws.ReviewError, "tag moved"):
            self.accept(candidate)
        self.assert_lock_unchanged()

    def test_accept_requires_fresh_baseline(self):
        candidate = self.prepare()
        updated = dict(self.lock, adaptationRevision="another-review")
        self.workflow.lock_path.write_bytes(uws.json_bytes(updated))
        with self.assertRaisesRegex(uws.ReviewError, "Stale candidate"):
            self.accept(candidate)
        self.assertEqual(json.loads(self.workflow.lock_path.read_text()), updated)

    def test_accept_refuses_modified_report(self):
        candidate = self.prepare()
        with (self.output / "review.md").open("a") as stream:
            stream.write("Changed after review\n")
        with self.assertRaisesRegex(uws.ReviewError, "report was modified"):
            self.accept(candidate)
        self.assert_lock_unchanged()

    def test_accept_refuses_modified_candidate_manifest(self):
        candidate = self.prepare()
        document = json.loads(candidate.read_text())
        document["preparedAt"] = "modified"
        candidate.write_bytes(uws.json_bytes(document))
        with self.assertRaisesRegex(uws.ReviewError, "report was modified"):
            self.accept(candidate)
        self.assert_lock_unchanged()

    def test_verify_refuses_missing_reference_hash(self):
        self.lock["files"].pop("src/go/core/exec.go")
        self.workflow.lock_path.write_bytes(uws.json_bytes(self.lock))
        with self.assertRaisesRegex(uws.ReviewError, "inventory or content"):
            self.workflow.verify()

    def test_verify_refuses_modified_hash(self):
        self.lock["files"]["src/go/core/codex.go"] = "0" * 64
        self.workflow.lock_path.write_bytes(uws.json_bytes(self.lock))
        with self.assertRaisesRegex(uws.ReviewError, "inventory or content"):
            self.workflow.verify()

    def test_verify_refuses_missing_license_notice(self):
        (self.root / "Upstream/LICENSE.UsageWindowStarter").unlink()
        with self.assertRaisesRegex(uws.ReviewError, "MIT notice"):
            self.workflow.verify()

    def test_accept_updates_only_after_passing_swift_tests(self):
        candidate = self.prepare()
        evidence = {"command": "swift test", "exitCode": 0, "outputSHA256": "1" * 64}
        with patch.object(self.workflow, "run_swift_tests", return_value=evidence) as tests:
            accepted = self.accept(candidate)
        tests.assert_called_once()
        self.assertEqual(accepted["commit"], self.second)
        self.assertEqual(accepted["adaptationRevision"], "native-v2")
        self.assertEqual(accepted["verification"], evidence)
        self.assertEqual(self.workflow.verify()["tag"], "v0.5.0")

    def test_swift_test_failure_preserves_lock(self):
        candidate = self.prepare()
        with patch.object(self.workflow, "run_swift_tests", side_effect=uws.ReviewError("swift test failed")):
            with self.assertRaisesRegex(uws.ReviewError, "swift test failed"):
                self.accept(candidate)
        self.assert_lock_unchanged()

    def test_real_verification_records_successful_nonempty_suite(self):
        result = subprocess.CompletedProcess(["swift", "test"], 0,
                                             b"Executed 270 tests, with 0 failures\n")
        with patch.object(uws.subprocess, "run", return_value=result) as run:
            evidence = self.workflow.run_swift_tests()
        self.assertEqual(run.call_args.args[0], ["swift", "test"])
        self.assertEqual(run.call_args.kwargs["cwd"], self.root.resolve())
        self.assertEqual(evidence["outputSHA256"], uws.sha256(result.stdout))
        self.assertEqual(evidence["exitCode"], 0)

    def test_success_exit_without_any_tests_is_not_verification(self):
        result = subprocess.CompletedProcess(["swift", "test"], 0,
                                             b"Test run with 0 tests passed\n")
        with patch.object(uws.subprocess, "run", return_value=result):
            with self.assertRaisesRegex(uws.ReviewError, "No passing Swift test suite"):
                self.workflow.run_swift_tests()
        self.assert_lock_unchanged()

    def test_real_verification_failure_retains_log_without_updating_lock(self):
        result = subprocess.CompletedProcess(["swift", "test"], 1, b"A regression failed\n")
        with patch.object(uws.subprocess, "run", return_value=result):
            with self.assertRaisesRegex(uws.ReviewError, "swift test failed"):
                self.workflow.run_swift_tests()
        self.assertTrue(any(path.read_bytes() == result.stdout
                            for path in self.workflow.cache.glob("swift-test-*.log")))
        self.assert_lock_unchanged()

    def test_accept_refuses_tag_moved_during_swift_tests(self):
        candidate = self.prepare()
        def move_tag():
            self.git("tag", "-f", "v0.5.0", self.first)
            return {"command": "swift test", "exitCode": 0}
        with patch.object(self.workflow, "run_swift_tests", side_effect=move_tag):
            with self.assertRaisesRegex(uws.ReviewError, "tag moved"):
                self.accept(candidate)
        self.assert_lock_unchanged()

    def test_accept_refuses_baseline_changed_during_swift_tests(self):
        candidate = self.prepare()
        updated = uws.json_bytes(dict(self.lock, adaptationRevision="concurrent-review"))
        def modify_baseline():
            self.workflow.lock_path.write_bytes(updated)
            return {"command": "swift test", "exitCode": 0}
        with patch.object(self.workflow, "run_swift_tests", side_effect=modify_baseline):
            with self.assertRaisesRegex(uws.ReviewError, "inputs changed"):
                self.accept(candidate)
        self.assertEqual(self.workflow.lock_path.read_bytes(), updated)

    def test_requires_explicit_review_and_new_adaptation_revision(self):
        candidate = self.prepare()
        with self.assertRaisesRegex(uws.ReviewError, "concrete review note"):
            self.workflow.accept(candidate, "native-v2", "ok")
        with self.assertRaisesRegex(uws.ReviewError, "new native adaptation"):
            self.workflow.accept(candidate, "native-v1", "Reviewed parser and Swift integration carefully.")
        self.assert_lock_unchanged()

    def test_cache_cannot_be_inside_application_repository(self):
        with self.assertRaisesRegex(uws.ReviewError, "outside"):
            uws.UpstreamReview(self.root, self.root / ".cache")

    def test_does_not_overwrite_previous_review_output(self):
        self.prepare()
        before = (self.output / "candidate.json").read_bytes()
        with self.assertRaisesRegex(uws.ReviewError, "already exists"):
            self.prepare()
        self.assertEqual((self.output / "candidate.json").read_bytes(), before)

    def test_invalid_tag_cannot_be_interpreted_as_an_option(self):
        with self.assertRaisesRegex(uws.ReviewError, "valid upstream tag"):
            self.workflow.prepare("--upload-pack=malicious", self.output)
        self.assert_lock_unchanged()

    def test_non_mit_license_change_is_refused(self):
        (self.source / "LICENSE").write_text("Different licensing terms\n")
        self.commit("Change license")
        self.git("tag", "v0.6.0")
        with self.assertRaisesRegex(uws.ReviewError, "licensing changed"):
            self.workflow.prepare("v0.6.0", self.output)
        self.assert_lock_unchanged()


if __name__ == "__main__":
    unittest.main()
