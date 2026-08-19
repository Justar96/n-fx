from __future__ import annotations

import hashlib
import os
import pathlib
import platform
import stat
import subprocess
import tarfile
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
INSTALLER = ROOT / "install.sh"
RELEASE_WORKFLOW = ROOT / ".github" / "workflows" / "release.yml"
DEV_RELEASE_WORKFLOW = ROOT / ".github" / "workflows" / "dev-release.yml"
LIBFX_WORKFLOW = ROOT / ".github" / "workflows" / "publish-libfx.yml"
PGSO_WORKFLOW = ROOT / ".github" / "workflows" / "pgso-macos-arm64.yml"
FULL_CI_WORKFLOW = ROOT / ".github" / "workflows" / "full-ci.yml"
UPSTREAM_CI_WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
BENCH_WORKFLOW = ROOT / ".github" / "workflows" / "bench.yml"
BINARY_SIZE_WORKFLOW = ROOT / ".github" / "workflows" / "binary-size.yml"
NFX_CI_WORKFLOW = ROOT / ".github" / "workflows" / "nfx-ci.yml"


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
            "cp \"$FAKE_RELEASE_DIR/$(basename \"$url\")\" \"$destination\"\n"
        )
        fake_curl.chmod(0o755)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def run_installer(self, version: str = "v0.0.4") -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(
            {
                "FAKE_RELEASE_DIR": str(self.release_dir),
                "NFX_INSTALL_DIR": str(self.install_dir),
                "PATH": f"{self.fake_bin}:{env['PATH']}",
            }
        )
        return subprocess.run(
            ["bash", str(INSTALLER), version],
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

    def test_rejects_checksum_mismatch(self) -> None:
        (self.release_dir / f"{self.asset}.sha256").write_text(
            f"{'0' * 64}  {self.asset}\n"
        )
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.install_dir / "nfx").exists())

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


if __name__ == "__main__":
    unittest.main()
