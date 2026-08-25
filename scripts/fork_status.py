from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import sys
from dataclasses import asdict, dataclass
from typing import Any


DEFAULT_MANIFEST = pathlib.Path("docs/fork-manifest.json")


class ForkStatusError(RuntimeError):
    pass


@dataclass(frozen=True)
class PathRule:
    path: str
    reason: str

    def matches(self, candidate: str) -> bool:
        if self.path.endswith("/"):
            return candidate.startswith(self.path)
        return candidate == self.path


@dataclass(frozen=True)
class Manifest:
    upstream_remote: str
    upstream_repository: str
    upstream_branch: str
    upstream_synchronized_version: str
    upstream_synchronized_sha: str
    fork_remote: str
    fork_repository: str
    fork_branch: str
    fork_owned: tuple[PathRule, ...]
    shared_integration: tuple[PathRule, ...]


@dataclass(frozen=True)
class ClassifiedPath:
    path: str
    category: str
    owner: str
    reason: str


@dataclass(frozen=True)
class StatusReport:
    repository: str
    current_branch: str
    upstream_ref: str
    upstream_sha: str
    fork_ref: str
    fork_sha: str
    merge_base: str
    pending_upstream_commits: int
    retained_fork_commits: int
    committed_patch_paths: int
    worktree_paths: int
    fork_owned_paths: int
    shared_integration_paths: int
    unclassified_paths: int
    paths: tuple[ClassifiedPath, ...]

    def to_json(self) -> dict[str, Any]:
        result = asdict(self)
        result["paths"] = [asdict(path) for path in self.paths]
        return result


def run_git(
    repo: pathlib.Path,
    *args: str,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        text=True,
        capture_output=True,
        check=False,
    )
    if check and result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        command = " ".join(("git", *args))
        raise ForkStatusError(f"{command} failed: {detail}")
    return result


def repository_root(path: pathlib.Path) -> pathlib.Path:
    result = run_git(path, "rev-parse", "--show-toplevel")
    return pathlib.Path(result.stdout.strip()).resolve()


def load_manifest(path: pathlib.Path) -> Manifest:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise ForkStatusError(f"fork manifest does not exist: {path}") from error
    except json.JSONDecodeError as error:
        raise ForkStatusError(f"fork manifest is invalid JSON: {error}") from error

    if not isinstance(raw, dict):
        raise ForkStatusError("fork manifest root must be an object")
    if raw.get("schema_version") != 1:
        raise ForkStatusError("fork manifest schema_version must be 1")

    def require_string(container: dict[str, Any], key: str, label: str) -> str:
        value = container.get(key)
        if not isinstance(value, str) or not value.strip():
            raise ForkStatusError(f"fork manifest {label}.{key} must be a string")
        return value.strip()

    def rules(key: str) -> tuple[PathRule, ...]:
        values = raw.get(key)
        if not isinstance(values, list):
            raise ForkStatusError(f"fork manifest {key} must be an array")
        result: list[PathRule] = []
        for index, value in enumerate(values):
            if not isinstance(value, dict):
                raise ForkStatusError(f"fork manifest {key}[{index}] must be an object")
            rule_path = require_string(value, "path", f"{key}[{index}]")
            reason = require_string(value, "reason", f"{key}[{index}]")
            path_body = rule_path[:-1] if rule_path.endswith("/") else rule_path
            if (
                rule_path.startswith("/")
                or "\\" in rule_path
                or not path_body
                or any(part in ("", ".", "..") for part in path_body.split("/"))
            ):
                raise ForkStatusError(
                    "fork manifest path must be normalized repository-relative "
                    f"POSIX text: {rule_path}"
                )
            result.append(PathRule(rule_path, reason))
        return tuple(result)

    upstream = raw.get("upstream")
    fork = raw.get("fork")
    if not isinstance(upstream, dict) or not isinstance(fork, dict):
        raise ForkStatusError("fork manifest upstream and fork entries must be objects")

    fork_owned = rules("fork_owned")
    shared_integration = rules("shared_integration")
    all_rules = (*fork_owned, *shared_integration)
    for index, rule in enumerate(all_rules):
        for other in all_rules[index + 1 :]:
            overlap = (
                rule.path == other.path
                or (rule.path.endswith("/") and other.path.startswith(rule.path))
                or (other.path.endswith("/") and rule.path.startswith(other.path))
            )
            if overlap:
                raise ForkStatusError(
                    "fork manifest paths must have one owner; overlapping rules: "
                    f"{rule.path}, {other.path}"
                )

    synchronized_version = require_string(
        upstream,
        "synchronized_version",
        "upstream",
    )
    if re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", synchronized_version) is None:
        raise ForkStatusError(
            "fork manifest upstream.synchronized_version must be a stable "
            "semantic version"
        )
    synchronized_sha = require_string(upstream, "synchronized_sha", "upstream")
    if re.fullmatch(r"[0-9a-f]{40}", synchronized_sha) is None:
        raise ForkStatusError(
            "fork manifest upstream.synchronized_sha must be a full lowercase "
            "commit SHA"
        )

    return Manifest(
        upstream_remote=require_string(upstream, "remote", "upstream"),
        upstream_repository=require_string(upstream, "repository", "upstream"),
        upstream_branch=require_string(upstream, "branch", "upstream"),
        upstream_synchronized_version=synchronized_version,
        upstream_synchronized_sha=synchronized_sha,
        fork_remote=require_string(fork, "remote", "fork"),
        fork_repository=require_string(fork, "repository", "fork"),
        fork_branch=require_string(fork, "branch", "fork"),
        fork_owned=fork_owned,
        shared_integration=shared_integration,
    )


def ensure_remote(repo: pathlib.Path, remote: str, repository: str) -> None:
    result = run_git(repo, "remote", "get-url", remote, check=False)
    if result.returncode == 0:
        return
    raise ForkStatusError(
        f"missing git remote {remote!r}; add it with: "
        f"git remote add {remote} {repository}"
    )


def fetch_refs(repo: pathlib.Path, manifest: Manifest) -> None:
    ensure_remote(repo, manifest.upstream_remote, manifest.upstream_repository)
    ensure_remote(repo, manifest.fork_remote, manifest.fork_repository)
    run_git(
        repo,
        "fetch",
        "--prune",
        manifest.upstream_remote,
        manifest.upstream_branch,
    )
    if manifest.fork_remote != manifest.upstream_remote:
        run_git(repo, "fetch", "--prune", manifest.fork_remote, manifest.fork_branch)


def resolve_ref(repo: pathlib.Path, ref: str, label: str) -> str:
    result = run_git(repo, "rev-parse", "--verify", ref, check=False)
    if result.returncode != 0:
        raise ForkStatusError(f"{label} ref does not exist: {ref}")
    return result.stdout.strip()


def current_branch(repo: pathlib.Path) -> str:
    result = run_git(repo, "symbolic-ref", "--quiet", "--short", "HEAD", check=False)
    return result.stdout.strip() if result.returncode == 0 else "(detached)"


def output_paths(repo: pathlib.Path, *args: str) -> set[str]:
    result = run_git(repo, *args)
    return {path for path in result.stdout.split("\0") if path}


def worktree_paths(repo: pathlib.Path) -> set[str]:
    return (
        output_paths(repo, "diff", "--name-only", "-z")
        | output_paths(repo, "diff", "--cached", "--name-only", "-z")
        | output_paths(repo, "ls-files", "--others", "--exclude-standard", "-z")
    )


def classify_path(path: str, manifest: Manifest) -> ClassifiedPath:
    for rule in manifest.fork_owned:
        if rule.matches(path):
            return ClassifiedPath(path, "fork_owned", "n-fx", rule.reason)
    for rule in manifest.shared_integration:
        if rule.matches(path):
            return ClassifiedPath(path, "shared_integration", "upstream+n-fx", rule.reason)
    return ClassifiedPath(
        path,
        "unclassified",
        "unassigned",
        "Classify this path before merging or move the change behind an existing seam",
    )


def build_report(
    repo: pathlib.Path,
    manifest: Manifest,
    upstream_ref: str,
    fork_ref: str,
) -> StatusReport:
    upstream_sha = resolve_ref(repo, upstream_ref, "upstream")
    fork_sha = resolve_ref(repo, fork_ref, "fork")
    synchronized_sha = resolve_ref(
        repo,
        manifest.upstream_synchronized_sha,
        "synchronized upstream",
    )
    for descendant, label in (
        (upstream_sha, "configured upstream"),
        (fork_sha, "fork"),
    ):
        ancestry = run_git(
            repo,
            "merge-base",
            "--is-ancestor",
            synchronized_sha,
            descendant,
            check=False,
        )
        if ancestry.returncode != 0:
            raise ForkStatusError(
                "manifest synchronized upstream commit "
                f"{synchronized_sha} is not an ancestor of the {label} ref"
            )
    synchronized_source = run_git(
        repo,
        "show",
        f"{synchronized_sha}:src/main.zig",
        check=False,
    )
    if synchronized_source.returncode != 0:
        raise ForkStatusError(
            "manifest synchronized upstream commit does not contain src/main.zig"
        )
    source_version_match = re.search(
        r'^pub const version = "([^"]+)";',
        synchronized_source.stdout,
        re.MULTILINE,
    )
    source_version = source_version_match.group(1) if source_version_match else ""
    if source_version != manifest.upstream_synchronized_version:
        raise ForkStatusError(
            "manifest synchronized upstream version does not match src/main.zig "
            f"at {synchronized_sha}: expected "
            f"{manifest.upstream_synchronized_version}, found {source_version or '(missing)'}"
        )
    merge_base = run_git(repo, "merge-base", upstream_ref, fork_ref).stdout.strip()
    divergence = run_git(
        repo,
        "rev-list",
        "--left-right",
        "--count",
        f"{upstream_ref}...{fork_ref}",
    ).stdout.split()
    if len(divergence) != 2:
        raise ForkStatusError("git rev-list returned an unexpected divergence count")

    committed = output_paths(
        repo,
        "diff",
        "--name-only",
        "-z",
        f"{merge_base}..{fork_ref}",
    )
    dirty = worktree_paths(repo)
    classified = tuple(
        classify_path(path, manifest) for path in sorted(committed | dirty)
    )
    return StatusReport(
        repository=str(repo),
        current_branch=current_branch(repo),
        upstream_ref=upstream_ref,
        upstream_sha=upstream_sha,
        fork_ref=fork_ref,
        fork_sha=fork_sha,
        merge_base=merge_base,
        pending_upstream_commits=int(divergence[0]),
        retained_fork_commits=int(divergence[1]),
        committed_patch_paths=len(committed),
        worktree_paths=len(dirty),
        fork_owned_paths=sum(path.category == "fork_owned" for path in classified),
        shared_integration_paths=sum(
            path.category == "shared_integration" for path in classified
        ),
        unclassified_paths=sum(path.category == "unclassified" for path in classified),
        paths=classified,
    )


def print_report(report: StatusReport, verbose: bool) -> None:
    print("n-fx fork status")
    print(f"  repository: {report.repository}")
    print(f"  current branch: {report.current_branch}")
    print(f"  upstream: {report.upstream_ref} ({report.upstream_sha[:12]})")
    print(f"  fork: {report.fork_ref} ({report.fork_sha[:12]})")
    print(f"  merge base: {report.merge_base[:12]}")
    print(f"  pending upstream commits: {report.pending_upstream_commits}")
    print(f"  retained fork commits: {report.retained_fork_commits}")
    print(f"  committed fork patch paths: {report.committed_patch_paths}")
    print(f"  current worktree paths: {report.worktree_paths}")
    print(f"  fork-owned paths: {report.fork_owned_paths}")
    print(f"  shared integration paths: {report.shared_integration_paths}")
    print(f"  unclassified paths: {report.unclassified_paths}")

    selected = report.paths if verbose else tuple(
        path for path in report.paths if path.category == "unclassified"
    )
    if selected:
        print("  paths:")
        for path in selected:
            print(f"    [{path.category}] {path.path}: {path.reason}")
    elif not verbose:
        print("  boundary: every changed path is classified")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Report n-fx divergence from upstream and verify that every fork patch "
            "path has an explicit owner."
        )
    )
    parser.add_argument("--repo", type=pathlib.Path, default=pathlib.Path.cwd())
    parser.add_argument("--manifest", type=pathlib.Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--upstream-ref")
    parser.add_argument("--fork-ref", default="HEAD")
    parser.add_argument(
        "--fetch",
        action="store_true",
        help="refresh the configured upstream and fork branches before reporting",
    )
    parser.add_argument("--json", action="store_true", dest="as_json")
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="print every classified path instead of only unclassified paths",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="exit with status 2 when a changed path is unclassified",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        repo = repository_root(args.repo.resolve())
        manifest_path = args.manifest
        if not manifest_path.is_absolute():
            manifest_path = repo / manifest_path
        manifest = load_manifest(manifest_path)
        if args.fetch:
            fetch_refs(repo, manifest)
        upstream_ref = args.upstream_ref or (
            f"{manifest.upstream_remote}/{manifest.upstream_branch}"
        )
        report = build_report(repo, manifest, upstream_ref, args.fork_ref)
    except (ForkStatusError, FileNotFoundError, json.JSONDecodeError) as error:
        print(f"fork status: {error}", file=sys.stderr)
        return 1

    if args.as_json:
        print(json.dumps(report.to_json(), indent=2, sort_keys=True))
    else:
        print_report(report, args.verbose)
    if args.check and report.unclassified_paths:
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
