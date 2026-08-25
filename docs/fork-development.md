# n-fx fork development

n-fx follows `vercel-labs/fx` closely while keeping fork behavior reviewable and
replaceable. The goal is not to duplicate upstream. The goal is to add a small
set of n-fx capabilities through explicit seams that survive upstream updates.

## Repository model

Use three ownership classes when changing the fork.

### Fork-owned paths

Fork-owned paths contain behavior that exists only in n-fx. Examples include
the CLIProxyAPI provider, the `nfx` installer, fork integration tests, and the
machine-readable agent interface.

Prefer putting new fork behavior in a fork-owned leaf module. A fork-owned
module may depend on typed upstream contracts, but shared upstream modules
should not depend on its internal details.

### Shared integration paths

Shared integration paths are upstream files with a narrow n-fx hook. Typical
examples are provider registration, command dispatch, configuration wiring,
release asset selection, and shared regression tests.

Keep changes in these files small and generic:

- register a typed provider or callback
- pass a contract through the composition root
- render a snapshot produced elsewhere
- select fork release metadata from one source

Do not put CLIProxyAPI request construction, n-fx release policy, or agent
stream serialization directly in shared integration files.

### Unclassified paths

A changed path that is neither fork-owned nor a declared integration path is
unclassified. Treat that as a design decision, not a bookkeeping error.

Before merging, either:

1. move the behavior behind an existing fork-owned seam
2. declare a new fork-owned path with a reason
3. declare a narrow shared integration path with a reason
4. contribute a generic change upstream and remove it from the fork patch

The machine-readable ownership contract lives in
[`fork-manifest.json`](fork-manifest.json).

## Inspect the fork patch

Add the canonical upstream remote once:

```bash
git remote add upstream https://github.com/vercel-labs/fx.git
git fetch upstream main
```

Then inspect divergence and path ownership:

```bash
python3 scripts/fork_status.py --fetch --check
python3 scripts/fork_status.py --verbose
```

The report compares `upstream/main` with `HEAD`, includes current worktree
changes, and groups every path as fork-owned, shared integration, or
unclassified. `--check` exits with status 2 when an unclassified path exists.
It never merges, rebases, resets, or edits files.

Use JSON when another agent or script owns the integration:

```bash
python3 scripts/fork_status.py --json > /tmp/nfx-fork-status.json
```

## Develop a fork feature

Start feature work from the latest integrated n-fx `main`, not directly from
`upstream/main`.

```bash
git fetch origin main
git switch -c feature/<name> origin/main
```

For each feature:

1. Define the typed contract first.
2. Put fork-only behavior in a fork-owned module.
3. Add the smallest possible registration hook to shared code.
4. Add a focused fork test and any shared regression test required by the hook.
5. Update `docs/fork-manifest.json` when the patch introduces a new path.
6. Run the boundary report before review.

A useful patch should make the ownership obvious from the file list. If most of
a feature lives in `src/main.zig`, command dispatch, or UI runtime files, the
feature needs another separation pass.

## Coordinate an upstream sync

Only one owner should perform an upstream merge at a time. Use a dedicated
worktree and announce it before starting so feature agents do not merge or
rebase the same refs concurrently.

A typical sync owner uses this shape:

```bash
git fetch --prune origin
git fetch --prune upstream
git worktree add ../n-fx-upstream-sync -b sync/upstream-YYYYMMDD origin/main
cd ../n-fx-upstream-sync
git merge --no-ff upstream/main
```

During conflict resolution:

- accept upstream structure for upstream-owned code
- preserve fork behavior inside fork-owned modules
- resolve shared integration paths manually against the new typed contracts
- avoid copying old shared files wholesale over newer upstream versions
- remove fork patches that upstream now provides
- update the manifest when an integration seam moves
- set `upstream.synchronized_sha` to the full upstream commit that was merged and
  `upstream.synchronized_version` to that source tree's `src/main.zig` version

Feature branches should continue independently and merge the completed sync
through normal review. They should not fetch, merge, or rewrite the active sync
worktree.

## Verify a completed sync

After conflict resolution, first inspect the patch boundary:

```bash
python3 scripts/fork_status.py --check --verbose
```

Then run the focused fork proof:

```bash
zig fmt --check src/
python3 -m unittest scripts.tests.test_fork_status scripts.tests.test_install -v
zig build
```

Run the focused Zig and E2E tests for every shared integration path touched by
the merge. Finally exercise the built binary, never an installed copy:

```bash
./zig-out/bin/fx help --json
./zig-out/bin/fx status --json
```

A sync is not ready until the current commit passes the repository's required
CI and the built binary has exercised the affected happy path.

The synchronized SHA and version are also the release provenance record. The
release workflow requires that exact SHA in repository history and verifies it
is an ancestor of the release source. Publication therefore does not depend on
the mutable contents of upstream `main` after the sync was reviewed.

Release reruns follow this state matrix:

| Version release | Stable pointers | Workflow behavior |
| --- | --- | --- |
| Missing | Any state | Build the exact release source once, publish it without overwrite, then repair pointers from its assets |
| Published with the exact asset set | Missing, draft, or incomplete | Skip all builds and repair pointers from the immutable version assets |
| Published with the exact asset set | Complete | Validate the version and pointer contents without replacing version assets |
| Draft, incomplete, or invalid | Any state | Stop before building or changing pointers and require explicit maintainer investigation |

Pointer repair publishes recoverable drafts and verifies checksums. The mutable
channel may replace stale metadata or remove unexpected assets. The fixed bridge
only gains missing assets after all existing bytes match its verified source;
conflicts and unexpected assets stop before any pointer mutation. Repair never
uses a fresh build when the version release already exists. A rerun against a
fully valid version, channel, and bridge performs validation only, with no
release create, edit, upload, or delete operation.

## Keep upstream integration small

When reviewing fork work, ask:

- Could this leaf behavior live entirely under a fork-owned path?
- Is the shared hook typed, narrow, and useful without n-fx-specific strings?
- Does one focused test own the fork capability end to end?
- Can an upstream sync delete or replace this feature without untangling core
  runtime state?
- Has upstream added equivalent behavior that lets this fork patch disappear?

The best upstream integration is the one that removes fork code over time.
