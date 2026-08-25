from __future__ import annotations

import hashlib
import json
import os
import pathlib
import platform
import re
import stat
import subprocess
import tarfile
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
INSTALLER = ROOT / "install.sh"
RELEASE_WORKFLOW = ROOT / ".github" / "workflows" / "release.yml"
PREPARE_RELEASE_WORKFLOW = ROOT / ".github" / "workflows" / "prepare-release.yml"
DEV_RELEASE_WORKFLOW = ROOT / ".github" / "workflows" / "dev-release.yml"
LIBFX_WORKFLOW = ROOT / ".github" / "workflows" / "publish-libfx.yml"
PGSO_WORKFLOW = ROOT / ".github" / "workflows" / "pgso-macos-arm64.yml"
FULL_CI_WORKFLOW = ROOT / ".github" / "workflows" / "full-ci.yml"
UPSTREAM_CI_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
BENCH_WORKFLOW = ROOT / ".github" / "workflows" / "bench.yml"
BINARY_SIZE_WORKFLOW = ROOT / ".github" / "workflows" / "binary-size.yml"
NFX_CI_WORKFLOW = ROOT / ".github" / "workflows" / "nfx-ci.yml"
NFX_BOUNDARY_WORKFLOW = ROOT / ".github" / "workflows" / "nfx-boundary.yml"
FORK_MANIFEST = ROOT / "docs" / "fork-manifest.json"

VERSION_RELEASE_ASSETS = (
    "install.sh",
    "latest.txt",
    "nfx-linux-aarch64.tar.gz",
    "nfx-linux-aarch64.tar.gz.sha256",
    "nfx-linux-x86_64.tar.gz",
    "nfx-linux-x86_64.tar.gz.sha256",
    "nfx-macos-aarch64.tar.gz",
    "nfx-macos-aarch64.tar.gz.sha256",
    "nfx-macos-x86_64.tar.gz",
    "nfx-macos-x86_64.tar.gz.sha256",
)


class InvalidReleaseState(ValueError):
    pass


def model_release_actions(
    version: str,
    channel: str,
    bridge: str,
    *,
    bridge_matches_source: bool = True,
    bridge_has_unexpected_asset: bool = False,
    bridge_has_non_uploaded_asset: bool = False,
) -> tuple[str, ...]:
    actions: list[str] = []
    if version == "missing":
        actions.extend(("build", "create-draft", "verify-draft", "publish-version"))
    elif version == "complete":
        actions.append("reuse-version")
    else:
        raise InvalidReleaseState("version release fails closed")

    if bridge != "missing" and (
        not bridge_matches_source
        or bridge_has_unexpected_asset
        or bridge_has_non_uploaded_asset
    ):
        raise InvalidReleaseState("bridge preflight fails before pointer mutation")

    if channel == "missing":
        actions.append("create-channel")
    elif channel == "complete":
        actions.append("validate-channel")
    elif channel in ("draft", "incomplete"):
        actions.append("repair-channel")
    else:
        raise InvalidReleaseState("unknown channel state")
    if bridge == "missing":
        actions.append("create-bridge")
    elif bridge == "complete":
        actions.append("validate-bridge")
    elif bridge in ("draft", "incomplete"):
        actions.extend(("add-missing-bridge-assets", "publish-bridge"))
    else:
        raise InvalidReleaseState("unknown bridge state")
    return tuple(actions)


def model_bridge_repair(
    existing: dict[str, bytes],
    expected: dict[str, bytes],
    states: dict[str, str] | None = None,
) -> dict[str, bytes]:
    states = states or {name: "uploaded" for name in existing}
    unexpected = existing.keys() - expected.keys()
    if unexpected:
        raise InvalidReleaseState("unexpected bridge asset")
    for name, content in existing.items():
        if states.get(name) != "uploaded":
            raise InvalidReleaseState("non-uploaded bridge asset")
        if content != expected[name]:
            raise InvalidReleaseState("conflicting bridge asset")
    return {**existing, **{name: content for name, content in expected.items() if name not in existing}}


def release_platform() -> str:
    os_name = {"Linux": "linux", "Darwin": "macos"}[platform.system()]
    arch = {
        "x86_64": "x86_64",
        "amd64": "x86_64",
        "arm64": "aarch64",
        "aarch64": "aarch64",
    }[platform.machine()]
    return f"{os_name}-{arch}"


class InstallerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp_dir.name)
        self.release_dir = self.root / "release"
        self.release_dir.mkdir()
        self.fake_bin = self.root / "bin"
        self.fake_bin.mkdir()
        self.install_dir = self.root / "installed"
        self.url_log = self.root / "urls.log"

        self.asset = f"nfx-{release_platform()}.tar.gz"
        payload = self.root / "nfx"
        payload.write_text("#!/bin/sh\nprintf 'installed test binary\\n'\n")
        payload.chmod(0o755)
        with tarfile.open(self.release_dir / self.asset, "w:gz") as archive:
            archive.add(payload, arcname="nfx")

        digest = hashlib.sha256((self.release_dir / self.asset).read_bytes()).hexdigest()
        (self.release_dir / f"{self.asset}.sha256").write_text(
            f"{digest}  {self.asset}\n"
        )
        (self.release_dir / "latest.txt").write_text("v0.0.6-nfx.1\n")

        fake_curl = self.fake_bin / "curl"
        fake_curl.write_text(
            "#!/bin/sh\n"
            "set -eu\n"
            "destination=''\n"
            "url=''\n"
            "while [ \"$#\" -gt 0 ]; do\n"
            "  case \"$1\" in\n"
            "    -o) destination=\"$2\"; shift 2 ;;\n"
            "    http*) url=\"$1\"; shift ;;\n"
            "    *) shift ;;\n"
            "  esac\n"
            "done\n"
            "printf '%s\\n' \"$url\" >> \"$FAKE_URL_LOG\"\n"
            "cp \"$FAKE_RELEASE_DIR/$(basename \"$url\")\" \"$destination\"\n"
        )
        fake_curl.chmod(0o755)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def run_installer(self, version: str | None = None) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(
            {
                "FAKE_RELEASE_DIR": str(self.release_dir),
                "FAKE_URL_LOG": str(self.url_log),
                "NFX_INSTALL_DIR": str(self.install_dir),
                "PATH": f"{self.fake_bin}:{env['PATH']}",
            }
        )
        argv = ["bash", str(INSTALLER)]
        if version is not None:
            argv.append(version)
        return subprocess.run(
            argv,
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_installs_verified_release_binary(self) -> None:
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        installed = self.install_dir / "nfx"
        self.assertTrue(installed.is_file())
        self.assertTrue(installed.stat().st_mode & stat.S_IXUSR)
        self.assertIn("to PATH to run nfx", result.stderr)
        self.assertNotIn("to PATH to run fx", result.stderr)
        run = subprocess.run(
            [str(installed)], text=True, capture_output=True, check=True
        )
        self.assertEqual(run.stdout, "installed test binary\n")
        urls = self.url_log.read_text().splitlines()
        self.assertEqual(
            urls[0],
            "https://github.com/Justar96/n-fx/releases/download/"
            "nfx-stable-channel/latest.txt",
        )
        self.assertIn("/releases/download/v0.0.6-nfx.1/", urls[1])

    def test_rejects_checksum_mismatch(self) -> None:
        (self.release_dir / f"{self.asset}.sha256").write_text(
            f"{'0' * 64}  {self.asset}\n"
        )
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.install_dir / "nfx").exists())

    def test_accepts_legacy_nfx_version_without_v_prefix(self) -> None:
        result = self.run_installer("0.0.3-nfx.1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.install_dir / "nfx").is_file())

    def test_accepts_strict_bridge_version_without_v_prefix(self) -> None:
        result = self.run_installer("0.0.5")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.install_dir / "nfx").is_file())

    def test_rejects_invalid_version_before_download(self) -> None:
        result = self.run_installer("latest/../../main")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("version must look like", result.stderr)


class ReleaseWorkflowTests(unittest.TestCase):
    def test_builds_every_supported_native_target(self) -> None:
        workflow = RELEASE_WORKFLOW.read_text()
        for target in (
            "x86_64-linux",
            "aarch64-linux",
            "x86_64-macos",
            "aarch64-macos",
        ):
            self.assertIn(f"target: {target}", workflow)

    def test_publishes_verified_github_release_assets_without_cdn_secrets(self) -> None:
        workflow = RELEASE_WORKFLOW.read_text()
        self.assertIn("softprops/action-gh-release@", workflow)
        self.assertIn("sha256sum --check nfx-*.tar.gz.sha256", workflow)
        self.assertIn("install.sh", workflow)
        self.assertIn("latest.txt", workflow)
        self.assertNotIn("BLOB_READ_WRITE_TOKEN", workflow)
        self.assertNotIn("blob.vercel-storage.com", workflow)

    def test_keeps_nfx_versions_and_publishes_legacy_bridge(self) -> None:
        workflow = RELEASE_WORKFLOW.read_text()
        self.assertIn("-nfx\\.", workflow)
        self.assertIn('UPSTREAM_BASE="${VERSION%%-nfx.*}"', workflow)
        self.assertIn('CHANNEL_TAG="nfx-stable-channel"', workflow)
        self.assertIn('BRIDGE_TAG="v0.0.5"', workflow)
        self.assertIn("make_latest: false", workflow)

    def test_release_uses_reviewed_upstream_provenance_without_live_main(self) -> None:
        workflow = RELEASE_WORKFLOW.read_text()
        manifest = json.loads(FORK_MANIFEST.read_text())
        upstream = manifest["upstream"]

        self.assertEqual(upstream["synchronized_version"], "0.0.6")
        self.assertRegex(upstream["synchronized_sha"], r"^[0-9a-f]{40}$")
        self.assertIn(".upstream.synchronized_version", workflow)
        self.assertIn(".upstream.synchronized_sha", workflow)
        self.assertIn(
            'git merge-base --is-ancestor "$PINNED_UPSTREAM_SHA" "$RELEASE_SHA"',
            workflow,
        )
        self.assertNotIn("raw.githubusercontent.com/vercel-labs/fx/main", workflow)
        self.assertNotIn("curl ", workflow)

    def test_release_state_matrix_separates_create_from_pointer_repair(self) -> None:
        workflow = RELEASE_WORKFLOW.read_text()
        inspect = workflow.split("  inspect_version:\n", 1)[1].split(
            "\n  build_version:\n", 1
        )[0]
        build = workflow.split("  build_version:\n", 1)[1].split(
            "\n  publish_version:\n", 1
        )[0]
        publish = workflow.split("  publish_version:\n", 1)[1].split(
            "\n  repair_pointers:\n", 1
        )[0]
        repair = workflow.split("  repair_pointers:\n", 1)[1]

        self.assertIn("validate_version_release", inspect)
        self.assertIn("CREATE_VERSION=false", inspect)
        self.assertIn("CREATE_VERSION=true", inspect)
        for create_job in (build, publish):
            self.assertIn(
                "needs.inspect_version.outputs.create_version == 'true'", create_job
            )

        # Missing version: publish must succeed before pointers run. Existing
        # valid version: publish is skipped and pointers reuse release assets.
        self.assertIn(
            "needs.inspect_version.outputs.create_version == 'true'", repair
        )
        self.assertIn("needs.publish_version.result == 'success'", repair)
        self.assertIn(
            "needs.inspect_version.outputs.create_version == 'false'", repair
        )
        self.assertIn("needs.publish_version.result == 'skipped'", repair)
        self.assertIn('gh release download "$RELEASE_TAG"', repair)
        self.assertNotIn("zig build", repair)

        cases = (
            (
                ("missing", "missing", "missing"),
                ("build", "create-draft", "verify-draft", "publish-version", "create-channel", "create-bridge"),
            ),
            (
                ("complete", "complete", "complete"),
                ("reuse-version", "validate-channel", "validate-bridge"),
            ),
            (
                ("complete", "draft", "draft"),
                ("reuse-version", "repair-channel", "add-missing-bridge-assets", "publish-bridge"),
            ),
            (
                ("complete", "incomplete", "incomplete"),
                ("reuse-version", "repair-channel", "add-missing-bridge-assets", "publish-bridge"),
            ),
        )
        for state, expected in cases:
            with self.subTest(state=state):
                self.assertEqual(model_release_actions(*state), expected)

        for invalid_version in ("draft", "incomplete"):
            with self.subTest(version=invalid_version):
                with self.assertRaisesRegex(InvalidReleaseState, "version"):
                    model_release_actions(invalid_version, "complete", "complete")

        second_run = model_release_actions("complete", "complete", "complete")
        mutation_actions = {
            "build",
            "create-draft",
            "publish-version",
            "create-channel",
            "repair-channel",
            "create-bridge",
            "add-missing-bridge-assets",
            "publish-bridge",
        }
        self.assertTrue(mutation_actions.isdisjoint(second_run))

    def test_version_release_is_never_overwritten_and_has_exact_assets(self) -> None:
        workflow = RELEASE_WORKFLOW.read_text()
        inspect = workflow.split("  inspect_version:\n", 1)[1].split(
            "\n  build_version:\n", 1
        )[0]
        publish = workflow.split("  publish_version:\n", 1)[1].split(
            "\n  repair_pointers:\n", 1
        )[0]
        repair = workflow.split("  repair_pointers:\n", 1)[1]

        self.assertIn("overwrite_files: false", publish)
        self.assertIn("fail_on_unmatched_files: true", publish)
        self.assertIn("draft: true", publish)
        self.assertIn("exists without a release; refusing to create", inspect)
        self.assertNotIn("--clobber", publish)
        self.assertIn('tag_sha" != "$SOURCE_SHA', publish)
        self.assertIn(".targetCommitish == $source", publish)
        self.assertIn(".isDraft == true", publish)
        self.assertIn(".isDraft == false", publish)
        self.assertLess(
            publish.index(".isDraft == true"),
            publish.index('gh release edit "$RELEASE_TAG"'),
        )
        self.assertLess(
            publish.index('gh release edit "$RELEASE_TAG"'),
            publish.rindex(".isDraft == false"),
        )
        self.assertIn("all(.assets[]; .state == \"uploaded\" and .size > 0)", publish)
        self.assertIn('filename" != "$expected_filename', publish)

        asset_blocks = re.findall(
            r"expected_version_assets\(\) \{\n"
            r"\s+cat <<'EOF'\n(.*?)\n\s+EOF",
            workflow,
            flags=re.DOTALL,
        )
        self.assertEqual(len(asset_blocks), 2)
        for block in asset_blocks:
            actual = tuple(line.strip() for line in block.splitlines())
            self.assertEqual(actual, VERSION_RELEASE_ASSETS)

        # Clobber is limited to the mutable channel, never the fixed bridge.
        channel_repair, bridge_repair = repair.split(
            "          bridge_expected=$(expected_version_assets)", 1
        )
        self.assertIn("--clobber", channel_repair)
        self.assertNotIn("--clobber", bridge_repair)

    def test_pointer_repair_handles_drafts_and_incomplete_asset_sets(self) -> None:
        repair = RELEASE_WORKFLOW.read_text().split("  repair_pointers:\n", 1)[1]

        self.assertIn("sync_channel_asset", repair)
        self.assertIn('asset_state" != "uploaded', repair)
        self.assertIn("preflight_bridge_assets", repair)
        self.assertIn("add_missing_bridge_assets", repair)
        self.assertGreaterEqual(repair.count("--draft=false"), 2)
        self.assertIn("BRIDGE_COMPLETE=true", repair)
        self.assertIn("BRIDGE_COMPLETE=false", repair)
        self.assertIn("refusing to mutate it", repair)
        self.assertIn("BRIDGE_NEEDS_EDIT=false", repair)
        self.assertIn('if [ "$BRIDGE_NEEDS_EDIT" = true ]', repair)
        self.assertIn("fully valid", (ROOT / "docs" / "fork-development.md").read_text())
        self.assertLess(
            repair.index("preflight_bridge_assets\n"),
            repair.index('if release_exists "$CHANNEL_TAG"'),
        )
        self.assertIn("sha256sum --check nfx-*.tar.gz.sha256", repair)
        self.assertIn('validate_release "$CHANNEL_TAG" "latest.txt" true', repair)
        self.assertIn(
            'validate_release "$BRIDGE_TAG" "$bridge_expected" false '
            '"$BRIDGE_TITLE" "$BRIDGE_NOTES" false',
            repair,
        )
        self.assertIn('gh release edit "$RELEASE_TAG"', repair)
        self.assertIn('current_latest_tag" != "$RELEASE_TAG', repair)
        self.assertIn('latest_tag" != "$RELEASE_TAG', repair)
        self.assertIn('current_latest_tag" = "$BRIDGE_TAG', repair)
        bridge_edit = repair.split('gh release edit "$BRIDGE_TAG"', 1)[1]
        self.assertIn("--latest=false", bridge_edit.split("fi", 1)[0])

    def test_release_reuses_exact_reviewed_head_ship_gates(self) -> None:
        workflow = RELEASE_WORKFLOW.read_text()
        publish = workflow.split("  publish_version:\n", 1)[1].split(
            "\n  repair_pointers:\n", 1
        )[0]
        repair = workflow.split("  repair_pointers:\n", 1)[1]

        self.assertIn("push:", workflow)
        self.assertIn("paths: [src/main.zig]", workflow)
        self.assertNotIn("workflow_run:", workflow)
        self.assertIn('GITHUB_REPOSITORY" != "Justar96/n-fx', workflow)
        self.assertIn('SHIP_SHA=$(git rev-parse "${RELEASE_SHA}^2")', workflow)
        self.assertIn('"${RELEASE_SHA}^{tree}"', workflow)
        self.assertIn('"${SHIP_SHA}^{tree}"', workflow)
        self.assertIn("merged release tree differs", workflow.lower())
        self.assertIn("commits/${RELEASE_SHA}/pulls", workflow)
        self.assertIn("should_release=false", workflow)
        for check_name in (
            "Full suite (linux-x86_64)",
            "Full suite (linux-aarch64)",
            "Full suite (macos-x86_64)",
            "Full suite (macos-aarch64)",
            "Fork integration",
            "Fork path ownership",
        ):
            self.assertIn(f'"{check_name}"', workflow)
        self.assertIn('commits/${SHIP_SHA}/check-runs', workflow)
        self.assertNotIn("for attempt in $(seq 1 90)", workflow)
        self.assertNotIn("sleep 30", workflow)
        self.assertIn("Release candidate $RELEASE_SHA is no longer the current main", workflow)
        self.assertIn("Reconfirm exact main before version mutation", publish)
        self.assertGreaterEqual(
            publish.count("is no longer the current main commit"),
            2,
        )
        self.assertLess(
            publish.rindex("is no longer the current main commit"),
            publish.index('gh release edit "$RELEASE_TAG"'),
        )
        self.assertIn("assert_candidate_is_current_main", repair)
        self.assertGreaterEqual(repair.count("assert_candidate_is_current_main"), 5)
        self.assertIn('RELEASE_BRANCH" != "main', workflow)

    def test_normal_prs_run_only_lightweight_fork_ci(self) -> None:
        focused = NFX_CI_WORKFLOW.read_text()
        boundary = NFX_BOUNDARY_WORKFLOW.read_text()
        self.assertIn("pull_request:", focused)
        self.assertIn("pull_request:", boundary)
        self.assertNotIn("push:", focused)
        self.assertNotIn("push:", boundary)

        for workflow in (
            FULL_CI_WORKFLOW,
            UPSTREAM_CI_WORKFLOW,
            BENCH_WORKFLOW,
            BINARY_SIZE_WORKFLOW,
            PGSO_WORKFLOW,
        ):
            content = workflow.read_text()
            self.assertNotIn("pull_request:", content)
            self.assertNotIn("push:", content)

        prepare = PREPARE_RELEASE_WORKFLOW.read_text()
        self.assertIn('gh workflow run full-ci.yml --ref "$BRANCH"', prepare)
        self.assertNotIn("gh workflow run ci.yml", prepare)
        self.assertNotIn("gh workflow run bench.yml", prepare)

    def test_bridge_conflicts_fail_before_any_modeled_pointer_mutation(self) -> None:
        expected = {
            "install.sh": b"verified installer",
            "latest.txt": b"v0.0.5\n",
        }
        matching = {"install.sh": expected["install.sh"]}
        matching_digest = hashlib.sha256(matching["install.sh"]).hexdigest()
        repaired = model_bridge_repair(matching, expected)
        self.assertEqual(
            hashlib.sha256(repaired["install.sh"]).hexdigest(),
            matching_digest,
        )
        self.assertEqual(repaired["latest.txt"], expected["latest.txt"])

        cases = (
            (
                {"install.sh": b"existing bridge sentinel"},
                None,
                "conflicting",
            ),
            ({"unexpected.bin": b"sentinel"}, None, "unexpected"),
            (
                {"install.sh": expected["install.sh"]},
                {"install.sh": "new"},
                "non-uploaded",
            ),
        )
        for existing, states, error in cases:
            before = {
                name: hashlib.sha256(content).hexdigest()
                for name, content in existing.items()
            }
            with self.subTest(error=error):
                with self.assertRaisesRegex(InvalidReleaseState, error):
                    model_bridge_repair(existing, expected, states)
                after = {
                    name: hashlib.sha256(content).hexdigest()
                    for name, content in existing.items()
                }
                self.assertEqual(after, before)
                self.assertNotIn("latest.txt", existing)

        for kwargs in (
            {"bridge_matches_source": False},
            {"bridge_has_unexpected_asset": True},
            {"bridge_has_non_uploaded_asset": True},
        ):
            mutation_log: list[str] = []
            with self.subTest(kwargs=kwargs):
                with self.assertRaisesRegex(InvalidReleaseState, "before pointer"):
                    mutation_log.extend(
                        model_release_actions(
                            "complete",
                            "incomplete",
                            "incomplete",
                            **kwargs,
                        )
                    )
                self.assertEqual(mutation_log, [])

    def test_prepares_upstream_aligned_nfx_versions(self) -> None:
        workflow = PREPARE_RELEASE_WORKFLOW.read_text()
        self.assertIn('CURRENT_BASE="${CURRENT%%-nfx.*}"', workflow)
        self.assertIn(".upstream.synchronized_version", workflow)
        self.assertIn(".upstream.synchronized_sha", workflow)
        self.assertIn("git ls-remote https://github.com/vercel-labs/fx.git", workflow)
        self.assertIn("sync upstream main", workflow)
        self.assertIn('NEW="${PINNED_UPSTREAM_VERSION}-nfx.${NEXT_REVISION}"', workflow)
        self.assertNotIn("raw.githubusercontent.com/vercel-labs/fx/main", workflow)
        self.assertNotIn("inputs.bump", workflow)

    def test_fork_skips_upstream_only_workflows(self) -> None:
        self.assertIn(
            "github.repository == 'vercel-labs/fx'", DEV_RELEASE_WORKFLOW.read_text()
        )
        self.assertIn(
            "github.repository == 'vercel-labs/fx'", LIBFX_WORKFLOW.read_text()
        )
        self.assertIn(
            "github.repository == 'vercel-labs/fx'", PGSO_WORKFLOW.read_text()
        )
        self.assertIn(
            "github.repository == 'vercel-labs/fx'", FULL_CI_WORKFLOW.read_text()
        )
        for workflow in (
            UPSTREAM_CI_WORKFLOW,
            BENCH_WORKFLOW,
            BINARY_SIZE_WORKFLOW,
        ):
            self.assertIn("github.repository == 'vercel-labs/fx'", workflow.read_text())

        focused = NFX_CI_WORKFLOW.read_text()
        self.assertIn("github.repository == 'Justar96/n-fx'", focused)
        self.assertIn("nfx-fork.test.ts", focused)
        self.assertIn("-Dtest-filter=CLIProxyAPI", focused)

    def test_fork_full_ci_keeps_native_matrix_and_aggregates(self) -> None:
        workflow = FULL_CI_WORKFLOW.read_text()
        native = workflow.split("  native:\n", 1)[1].split("\n  e2e:\n", 1)[0]
        e2e = workflow.split("  e2e:\n", 1)[1].split("\n  full-suite:\n", 1)[0]
        full_suite = workflow.split("  full-suite:\n", 1)[1]

        self.assertNotIn("github.repository", native)
        self.assertIn("optimize: [Debug, ReleaseSafe]", native)
        self.assertNotIn("pull_request:", workflow)
        self.assertNotIn("push:", workflow)
        self.assertIn("workflow_dispatch:", workflow)
        self.assertIn("github.repository == 'vercel-labs/fx'", e2e)
        self.assertIn("if: ${{ always() }}", full_suite)
        self.assertNotIn("always() && github.repository", full_suite)
        self.assertIn(
            "REQUIRE_E2E: ${{ github.repository == 'vercel-labs/fx' }}",
            full_suite,
        )


if __name__ == "__main__":
    unittest.main()
