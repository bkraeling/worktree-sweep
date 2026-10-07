---
name: worktree-sweep
description: Sweep git worktrees across every attached repo and remove the ones whose pull request is no longer open, after showing exactly what will be deleted and getting confirmation. Use when the user runs /worktree-sweep, or asks to clean up, prune, or tidy stale worktrees ("remove worktrees for merged PRs", "which worktrees can I delete?", "clean up my worktrees").
---

# Worktree sweep

Worktrees pile up: one per PR, left behind long after the PR merged. They hold branch names hostage (`git worktree list` is the only way to find out why `git checkout apo-1234` fails) and cost real disk. This skill finds the ones whose PR is closed or merged, shows them, and removes them **only after the user confirms**.

Nothing is ever removed without an explicit yes in the conversation.

## The helper

```bash
SWEEP=~/.claude/skills/worktree-sweep/scripts/worktree-sweep.sh

"$SWEEP" scan <repo-path>... [--json <out>] [--claude-only]   # read-only
"$SWEEP" remove <worktree-path>... [--delete-branch] [--force]
"$SWEEP" prune <repo-path>...                                  # drop records for missing dirs
```

`scan` is strictly read-only. It resolves each path to its main checkout, enumerates every worktree with `git worktree list --porcelain`, and makes **exactly one GitHub GraphQL request per repository** — never one per branch — so a sweep over ten repos costs ten requests against the shared 5,000/hour limit. It does not retry on failure; a repo whose lookup fails is reported as unchecked rather than re-queried.

## Workflow

### 1. Scan

Pass **every working directory attached to the session** — the primary one plus all additional directories — as separate arguments in a single `scan` call. Don't scan one repo per call; one call keeps the report coherent and the request count minimal.

Each repo's worktrees are enumerated from its main checkout, so worktrees living outside the repo directory (`~/conductor/workspaces/…`, `~/.cursor/worktrees/…`) are picked up too. They are tagged `[outside .claude/worktrees]` in the report — these belong to other tools, so call them out separately when confirming. Use `--claude-only` if the user wants the sweep restricted to Claude-managed worktrees.

### 2. Present the plan and ask

Report what the scan found, grouped by action. Keep it short — path, branch, PR number and state, one-line reason:

- **REMOVE** — PR is MERGED or CLOSED, working tree clean, HEAD holds nothing the PR never saw. These are the deletion candidates.
- **PRUNE** — the directory is already gone; only the git bookkeeping is left. Cleared with `"$SWEEP" prune`, no data at risk.
- **REVIEW** — needs a human. Never fold these into the removal list on your own.
- **KEEP** — PR is open. Say the count; don't list them.

Then **ask for confirmation** before touching anything. State the number of worktrees, name the repos, and offer the obvious choices: remove everything under REMOVE, remove a subset, or cancel. Wait for a clear yes. If the user says "yes" to a smaller set, remove only that set.

Surface the REVIEW items in the same message so the user can promote any of them in their answer — but a REVIEW item is only ever removed when the user names it.

### 3. Remove

```bash
"$SWEEP" remove <path> <path> ...
```

It refuses the session's own worktree, resolves each path back to its repo, and reports `REMOVED` or `FAIL` per worktree.

`git worktree remove` fails on most real repos here, so the helper re-checks cleanliness itself, immediately before deleting, and finishes the job when — and only when — the tree is clean:

- **Gitignored build output.** git deregisters the worktree, then won't `rmdir` over `node_modules`, `dist`, `.meteor/local` or `.env`, leaving an orphaned directory. A clean tree means everything left is disposable.
- **Submodules.** `working trees containing submodules cannot be moved or removed` — git refuses outright and leaves the worktree registered. Any repo with populated submodules hits this.
- **`.DS_Store` races.** Finder and watchman recreate `.DS_Store` under `rm`, which then reports `Directory not empty`. The helper retries.

A worktree that is *not* clean is never deleted by this fallback — it stays a `FAIL`.

- `--force` only when the user has seen the specific dirty worktree and asked for it anyway.
- `--delete-branch` only when the user asks for branches cleaned up too. It uses `git branch -d` (safe delete). **Expect most branches to survive this**: GitHub squash-merges, so git does not consider the branch merged. Report how many were kept and let the user decide about `git branch -D`; never force-delete a branch on your own.

Do not edit this script while a removal is running — bash reads the file as it executes. Stop the run first.

### 4. Report

Say what was removed, what failed and why, and how much is left. If anything failed, don't retry it silently — report it.

## What counts as removable

A worktree is a REMOVE candidate only when all of these hold:

1. It is **not** the repo's main checkout (never touched, at any point).
2. It is **not** the worktree this session is running in.
3. It is not locked.
4. Its PR is MERGED or CLOSED. The PR is matched by branch name (`headRefName`), by directory name for `pr-1234`-style review checkouts, and by which PRs contain the checked-out commit — that last one is what identifies detached-HEAD worktrees and survives the remote branch being deleted after a merge.
5. `git status --porcelain` is empty.
6. HEAD is the PR head, a commit belonging to that PR, or an ancestor of the PR head. Anything else means local commits the PR never contained — that is REVIEW, not REMOVE.

Everything else lands in REVIEW with the reason attached. The common ones:

| Reason | What it means |
| --- | --- |
| `no pull request found` | Branch was never pushed, or the PR lives in a fork. The work may exist nowhere else — always ask. |
| `uncommitted changes` | Real edits sitting in the worktree. Ask before discarding; offer to show the diff. |
| `HEAD has commits the PR head does not` | Work committed after the PR, or on an unrelated branch. |
| `no github.com origin` / `GitHub lookup failed` | PR state unknown. Never guess merged. |

## Rules

- Confirmation is not optional, and it is not satisfied by the user having asked for the sweep. They asked for the list; the list is what they approve.
- Never remove a worktree with an open PR, even a draft.
- Never touch a repo's main checkout, and never `git worktree prune` as a way of getting rid of a directory that still exists.
- No retry loops around `gh`. If a lookup fails, report the repo as unchecked and move on.
- Removing a worktree does not delete its branch unless asked, and never deletes a remote branch.
