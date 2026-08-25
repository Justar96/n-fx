from __future__ import annotations

import json
import pathlib
import subprocess
import tempfile
import unittest

from scripts import fork_status


class PathRuleTests(unittest.TestCase):
    def test_exact_rule_matches_only_one_path(self) -> None:
        rule = fork_status.PathRule("README.md", "Product entry point")
        self.assertTrue(rule.matches("README.md"))
        self.assertFalse(rule.matches("docs/README.md"))

    def test_directory_rule_matches_descendants(self) -> None:
        rule = fork_status.PathRule("src/cliproxyapi/", "Fork provider")
        self.assertTrue(rule.matches("src/cliproxyapi/config.zig"))
        self.assertFalse(rule.matches("src/cliproxyapi.zig"))


class ManifestTests(unittest.TestCase):
    def write_manifest(self, root: pathlib.Path, payload: object) -> pathlib.Path:
        path = root / "fork-manifest.json"
        path.write_text(json.dumps(payload), encoding="utf-8")
        return path

    def valid_payload(self) -> dict[str, object]:
        return {
            "schema_version": 1,
            "upstream": {
                "remote": "upstream",
                "repository": "https://github.com/vercel-labs/fx.git",
                "branch": "main",
            },
            "fork": {
                "remote": "origin",
                "repository": "https://github.com/Justar96/n-fx.git",
                "branch": "main",
            },
            "fork_owned": [
                {"path": "src/cliproxyapi/", "reason": "Fork provider"}
            ],
            "shared_integration": [
                {"path": "src/main.zig", "reason": "Composition hook"}
            ],
        }

    def test_loads_valid_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = self.write_manifest(pathlib.Path(temp_dir), self.valid_payload())
            manifest = fork_status.load_manifest(path)
        self.assertEqual(manifest.upstream_remote, "upstream")
        self.assertEqual(
            manifest.upstream_repository,
            "https://github.com/vercel-labs/fx.git",
        )
        self.assertEqual(manifest.fork_branch, "main")
        self.assertEqual(manifest.fork_owned[0].path, "src/cliproxyapi/")

    def test_rejects_non_object_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            path = self.write_manifest(pathlib.Path(temp_dir), [])
            with self.assertRaisesRegex(fork_status.ForkStatusError, "root"):
                fork_status.load_manifest(path)

    def test_rejects_duplicate_ownership(self) -> None:
        payload = self.valid_payload()
        payload["shared_integration"] = [
            {"path": "src/cliproxyapi/", "reason": "Ambiguous owner"}
        ]
        with tempfile.TemporaryDirectory() as temp_dir:
            path = self.write_manifest(pathlib.Path(temp_dir), payload)
            with self.assertRaisesRegex(fork_status.ForkStatusError, "one owner"):
                fork_status.load_manifest(path)

    def test_rejects_absolute_paths(self) -> None:
        payload = self.valid_payload()
        payload["fork_owned"] = [
            {"path": "/tmp/provider.zig", "reason": "Invalid path"}
        ]
        with tempfile.TemporaryDirectory() as temp_dir:
            path = self.write_manifest(pathlib.Path(temp_dir), payload)
            with self.assertRaisesRegex(
                fork_status.ForkStatusError,
                "repository-relative",
            ):
                fork_status.load_manifest(path)

    def test_rejects_parent_traversal_paths(self) -> None:
        payload = self.valid_payload()
        payload["fork_owned"] = [
            {"path": "../src/cliproxyapi/", "reason": "Invalid path"}
        ]
        with tempfile.TemporaryDirectory() as temp_dir:
            path = self.write_manifest(pathlib.Path(temp_dir), payload)
            with self.assertRaisesRegex(
                fork_status.ForkStatusError,
                "normalized repository-relative",
            ):
                fork_status.load_manifest(path)

    def test_rejects_overlapping_directory_ownership(self) -> None:
        payload = self.valid_payload()
        payload["shared_integration"] = [
            {"path": "src/cliproxyapi/provider.zig", "reason": "Ambiguous owner"}
        ]
        with tempfile.TemporaryDirectory() as temp_dir:
            path = self.write_manifest(pathlib.Path(temp_dir), payload)
            with self.assertRaisesRegex(fork_status.ForkStatusError, "overlapping rules"):
                fork_status.load_manifest(path)


class ClassificationTests(unittest.TestCase):
    def manifest(self) -> fork_status.Manifest:
        return fork_status.Manifest(
            upstream_remote="upstream",
            upstream_repository="https://github.com/vercel-labs/fx.git",
            upstream_branch="main",
            fork_remote="origin",
            fork_repository="https://github.com/Justar96/n-fx.git",
            fork_branch="main",
            fork_owned=(
                fork_status.PathRule("src/cliproxyapi/", "Fork provider"),
            ),
            shared_integration=(
                fork_status.PathRule("src/main.zig", "Composition hook"),
            ),
        )

    def test_classifies_fork_owned_path(self) -> None:
        result = fork_status.classify_path(
            "src/cliproxyapi/provider.zig",
            self.manifest(),
        )
        self.assertEqual(result.category, "fork_owned")
        self.assertEqual(result.owner, "n-fx")

    def test_classifies_shared_integration_path(self) -> None:
        result = fork_status.classify_path("src/main.zig", self.manifest())
        self.assertEqual(result.category, "shared_integration")
        self.assertEqual(result.owner, "upstream+n-fx")

    def test_marks_unknown_path_unclassified(self) -> None:
        result = fork_status.classify_path("src/ui/new_feature.zig", self.manifest())
        self.assertEqual(result.category, "unclassified")
        self.assertEqual(result.owner, "unassigned")


class StatusReportTests(unittest.TestCase):
    def git(self, repo: pathlib.Path, *args: str) -> str:
        result = subprocess.run(
            ["git", "-C", str(repo), *args],
            text=True,
            capture_output=True,
            check=True,
        )
        return result.stdout.strip()

    def test_reports_divergence_and_worktree_ownership(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = pathlib.Path(temp_dir) / "repo"
            root.mkdir()
            self.git(root, "init", "-b", "main")
            self.git(root, "config", "user.name", "n-fx test")
            self.git(root, "config", "user.email", "nfx@example.test")

            (root / "README.md").write_text("base\n", encoding="utf-8")
            self.git(root, "add", "README.md")
            self.git(root, "commit", "-m", "base")
            self.git(root, "branch", "upstream-main")

            provider_dir = root / "src" / "cliproxyapi"
            provider_dir.mkdir(parents=True)
            (provider_dir / "provider.zig").write_text("fork\n", encoding="utf-8")
            self.git(root, "add", "src/cliproxyapi/provider.zig")
            self.git(root, "commit", "-m", "fork provider")

            self.git(root, "switch", "upstream-main")
            (root / "UPSTREAM.md").write_text("upstream\n", encoding="utf-8")
            self.git(root, "add", "UPSTREAM.md")
            self.git(root, "commit", "-m", "upstream change")
            self.git(root, "switch", "main")

            (provider_dir / "local.zig").write_text("local\n", encoding="utf-8")
            (root / "unexpected.txt").write_text("unknown\n", encoding="utf-8")
            before = self.git(root, "status", "--short")

            manifest = fork_status.Manifest(
                upstream_remote="upstream",
                upstream_repository="https://github.com/vercel-labs/fx.git",
                upstream_branch="main",
                fork_remote="origin",
                fork_repository="https://github.com/Justar96/n-fx.git",
                fork_branch="main",
                fork_owned=(
                    fork_status.PathRule("src/cliproxyapi/", "Fork provider"),
                ),
                shared_integration=(),
            )
            report = fork_status.build_report(
                root,
                manifest,
                "upstream-main",
                "HEAD",
            )
            after = self.git(root, "status", "--short")

        self.assertEqual(report.pending_upstream_commits, 1)
        self.assertEqual(report.retained_fork_commits, 1)
        self.assertEqual(report.committed_patch_paths, 1)
        self.assertEqual(report.worktree_paths, 2)
        self.assertEqual(report.fork_owned_paths, 2)
        self.assertEqual(report.unclassified_paths, 1)
        self.assertEqual(before, after)

    def test_worktree_paths_preserve_embedded_newlines(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = pathlib.Path(temp_dir) / "repo"
            root.mkdir()
            self.git(root, "init", "-b", "main")
            unusual_path = "unexpected\nfile.txt"
            (root / unusual_path).write_text("unknown\n", encoding="utf-8")

            paths = fork_status.worktree_paths(root)

        self.assertEqual(paths, {unusual_path})


class RepositoryManifestTests(unittest.TestCase):
    def test_repository_manifest_classifies_fork_tooling(self) -> None:
        root = pathlib.Path(__file__).resolve().parents[2]
        manifest = fork_status.load_manifest(root / "docs" / "fork-manifest.json")
        for path in (
            "docs/fork-development.md",
            "docs/fork-manifest.json",
            "scripts/fork_status.py",
            "scripts/tests/test_fork_status.py",
        ):
            with self.subTest(path=path):
                self.assertNotEqual(
                    fork_status.classify_path(path, manifest).category,
                    "unclassified",
                )


if __name__ == "__main__":
    unittest.main()
