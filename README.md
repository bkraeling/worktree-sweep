# worktree-sweep

A [Claude Code](https://claude.com/claude-code) skill that finds git worktrees whose pull request is no longer open, shows you exactly what it proposes to delete, and removes them only after you confirm.

Worktrees pile up — one per PR, left behind long after the PR merged. They hold branch names hostage and cost real disk.

## Install

```bash
tar xzf worktree-sweep-skill.tar.gz -C ~/.claude/skills/
```

Or clone straight in:

```bash
git clone https://github.com/bkraeling/worktree-sweep ~/.claude/skills/worktree-sweep
```

Then run `/worktree-sweep` in Claude Code. Requires `git`, `jq`, and an authenticated [`gh`](https://cli.github.com).

## Standalone use

The helper works on its own, without Claude:

```bash
./scripts/worktree-sweep.sh scan <repo-path>...        # read-only report
./scripts/worktree-sweep.sh remove <worktree-path>...  # delete
./scripts/worktree-sweep.sh prune <repo-path>...       # drop dangling records
```

## How it decides

A worktree is only a removal candidate when its PR is **merged or closed**, the working tree is **clean**, and HEAD holds **nothing the PR never saw**. Everything else is reported for a human to look at, with the reason attached. The repo's main checkout, the worktree you're currently in, locked worktrees, and anything with an open PR are never candidates.

PRs are matched three ways, so detached-HEAD checkouts and deleted remote branches still resolve:

1. branch name (`headRefName`)
2. directory name, for `pr-1234`-style review checkouts
3. which PRs contain the checked-out commit

## Rate limits

`scan` makes **exactly one GraphQL request per repository** — never one per branch — so sweeping ten repos costs ten requests. It never retries on failure; a repo whose lookup fails is reported as unchecked.

## Things worth knowing

`git worktree remove` fails on most real-world repos, so the helper re-checks cleanliness itself immediately before deleting and finishes the job when — and only when — the tree is clean:

- **Gitignored build output.** git deregisters the worktree, then won't `rmdir` over `node_modules`, `dist` or `.env`, leaving an orphaned directory.
- **Submodules.** `working trees containing submodules cannot be moved or removed` — git refuses outright.
- **`.DS_Store` races.** Finder and watchman recreate it under `rm`, which then reports `Directory not empty`.

**This means removal deletes gitignored files, including `.env`.** That is intended for stale merged-PR worktrees, but know it before your first run.

Branch deletion is opt-in (`--delete-branch`) and uses `git branch -d`. Expect most branches to survive it: GitHub squash-merges, so git does not consider them merged.

## License

MIT
