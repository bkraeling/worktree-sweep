#!/usr/bin/env bash
# worktree-sweep — find git worktrees whose PR is no longer open, and remove them.
#
#   worktree-sweep.sh scan <repo-path>... [--json <out>] [--claude-only]
#   worktree-sweep.sh remove <worktree-path>... [--delete-branch] [--force]
#   worktree-sweep.sh prune <repo-path>...
#
# scan is read-only. It makes exactly ONE GitHub GraphQL request per repository
# (never one per branch) to stay well inside the shared 5,000/hour rate limit.

set -uo pipefail

SELF_WT=""
if SELF_WT_RAW=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null); then
  SELF_WT="$SELF_WT_RAW"
fi

die() { printf 'worktree-sweep: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }

# ---------------------------------------------------------------- helpers ---

# Absolute path of a repo's MAIN checkout, given any path inside it.
main_root_of() {
  local d="$1" common
  common=$(git -C "$d" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  common=${common%/}
  ( cd "$(dirname "$common")" >/dev/null 2>&1 && pwd )
}

# owner/repo for a github.com origin, empty otherwise.
nwo_of() {
  local url="$1"
  url=${url%.git}
  case "$url" in
    git@github.com:*)      printf '%s' "${url#git@github.com:}" ;;
    ssh://git@github.com/*) printf '%s' "${url#ssh://git@github.com/}" ;;
    https://github.com/*)  printf '%s' "${url#https://github.com/}" ;;
    *) return 1 ;;
  esac
}

json_str() { printf '%s' "$1" | jq -Rs .; }

# ------------------------------------------------------------------- scan ---

scan() {
  local out_json="" claude_only=0 repos=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) out_json="${2:-}"; shift 2 ;;
      --claude-only) claude_only=1; shift ;;
      -*) die "unknown scan flag: $1" ;;
      *) repos+=("$1"); shift ;;
    esac
  done
  [ ${#repos[@]} -gt 0 ] || die "scan needs at least one repo path"
  [ -n "$out_json" ] || out_json="$(mktemp -t worktree-sweep).json"

  # Resolve every input path to its main checkout, de-duplicated.
  local roots=() r root seen
  for r in "${repos[@]}"; do
    [ -d "$r" ] || { note "skip (not a directory): $r"; continue; }
    root=$(main_root_of "$r") || { note "skip (not a git repo): $r"; continue; }
    seen=0
    for existing in ${roots[@]+"${roots[@]}"}; do
      [ "$existing" = "$root" ] && seen=1 && break
    done
    [ $seen -eq 0 ] && roots+=("$root")
  done
  [ ${#roots[@]} -gt 0 ] || die "no git repositories among the given paths"

  local all_file; all_file=$(mktemp)
  printf '[]' > "$all_file"

  for root in "${roots[@]}"; do
    scan_repo "$root" "$claude_only" "$all_file"
  done

  jq 'sort_by(.repo, .path)' "$all_file" > "$out_json"
  rm -f "$all_file"
  render_table "$out_json"
  printf '\nJSON: %s\n' "$out_json"
}

scan_repo() {
  local root="$1" claude_only="$2" all_file="$3"
  local remote nwo
  remote=$(git -C "$root" remote get-url origin 2>/dev/null || true)
  nwo=$(nwo_of "$remote" 2>/dev/null || true)

  # --- enumerate worktrees (porcelain) ---
  local paths=() heads=() branches=() flags=()
  local wpath="" whead="" wbranch="" wflag="" line
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "worktree "*) wpath="${line#worktree }"; whead=""; wbranch=""; wflag="" ;;
      "HEAD "*)     whead="${line#HEAD }" ;;
      "branch "*)   wbranch="${line#branch refs/heads/}" ;;
      "detached")   wbranch="" ;;
      "locked"*)    wflag="locked" ;;
      "prunable"*)  wflag="prunable" ;;
      "")
        if [ -n "$wpath" ]; then
          paths+=("$wpath"); heads+=("$whead"); branches+=("$wbranch"); flags+=("$wflag")
        fi
        wpath=""
        ;;
    esac
  done < <(git -C "$root" worktree list --porcelain; printf '\n')
  if [ -n "$wpath" ]; then
    paths+=("$wpath"); heads+=("$whead"); branches+=("$wbranch"); flags+=("$wflag")
  fi

  # --- build one GraphQL query covering every worktree in this repo ---
  local n=${#paths[@]} i alias q="" prnum
  local owner="" name=""
  if [ -n "$nwo" ]; then owner="${nwo%%/*}"; name="${nwo##*/}"; fi

  local pr_json="{}"
  if [ -n "$nwo" ]; then
    for ((i=0; i<n; i++)); do
      [ "${paths[$i]}" = "$root" ] && continue          # never the main checkout
      [ "${flags[$i]}" = "prunable" ] && continue
      alias="w$i"
      prnum=$(basename "${paths[$i]}" | sed -n 's/^pr-\([0-9][0-9]*\).*$/\1/p')
      if [ -n "${branches[$i]}" ]; then
        q+="  $alias: pullRequests(headRefName: $(json_str "${branches[$i]}"), first: 10, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { number state isDraft url title headRefOid updatedAt } }"$'\n'
      elif [ -n "$prnum" ]; then
        q+="  $alias: pullRequest(number: $prnum) { number state isDraft url title headRefOid updatedAt }"$'\n'
      fi
      # Which PRs contain this exact commit? Answers "is HEAD part of the PR, or
      # is it local work that was never reviewed?" without a second request.
      if [ -n "${heads[$i]}" ]; then
        q+="  c$i: object(oid: $(json_str "${heads[$i]}")) { ... on Commit { associatedPullRequests(first: 10) { nodes { number state isDraft url title headRefOid updatedAt } } } }"$'\n'
      fi
    done

    if [ -n "$q" ]; then
      local qfile; qfile=$(mktemp)
      { printf 'query {\n  repository(owner: %s, name: %s) {\n' "$(json_str "$owner")" "$(json_str "$name")"
        printf '%s' "$q"
        printf '  }\n}\n'; } > "$qfile"
      # ONE request. No retry loop — per the GitHub rate-limit rule.
      if ! pr_json=$(gh api graphql -F query=@"$qfile" 2>"$qfile.err" | jq -c '.data.repository // {}'); then
        note "GitHub lookup failed for $nwo — worktrees marked 'unchecked'. $(head -3 "$qfile.err" 2>/dev/null)"
        pr_json=""
      fi
      rm -f "$qfile" "$qfile.err"
    fi
  fi

  # --- classify each worktree ---
  local recs; recs=$(mktemp); printf '[]' > "$recs"
  for ((i=0; i<n; i++)); do
    local p="${paths[$i]}" head="${heads[$i]}" br="${branches[$i]}" fl="${flags[$i]}"
    [ "$p" = "$root" ] && continue
    local managed=false
    case "$p" in */.claude/worktrees/*) managed=true ;; esac
    [ "$claude_only" = "1" ] && [ "$managed" != "true" ] && continue

    local pr='null' pr_state="" pr_head="" pr_num="" head_prs="[]"
    if [ -n "$pr_json" ] && [ "$fl" != "prunable" ]; then
      head_prs=$(printf '%s' "$pr_json" | jq -c --arg c "c$i" \
        '(.[$c].associatedPullRequests.nodes // [])')
      pr=$(printf '%s' "$pr_json" | jq -c --arg a "w$i" --argjson hp "$head_prs" '
        (.[$a] // null) as $v
        | (if $v == null then $hp
           elif ($v | has("nodes")) then $v.nodes
           else [$v] end) as $cands
        | ((if ($cands | length) > 0 then $cands else $hp end)
           | (map(select(.state == "OPEN")) | sort_by(.updatedAt) | reverse)
             + (map(select(.state != "OPEN")) | sort_by(.updatedAt) | reverse))[0] // null')
      pr_state=$(printf '%s' "$pr" | jq -r '.state // ""')
      pr_head=$(printf '%s' "$pr" | jq -r '.headRefOid // ""')
      pr_num=$(printf '%s' "$pr" | jq -r '.number // ""')
    fi

    # local state
    local dirty=false ahead=false exists=true
    if [ ! -d "$p" ]; then
      exists=false
    else
      [ -n "$(git -C "$p" status --porcelain --ignore-submodules=none 2>/dev/null)" ] && dirty=true
      # Does this checkout hold work the PR never saw? Only then is it unsafe.
      if [ -n "$pr_num" ] && [ -n "$head" ] && [ "$pr_head" != "$head" ]; then
        if printf '%s' "$head_prs" | jq -e --argjson n "$pr_num" 'any(.number == $n)' >/dev/null 2>&1; then
          : # HEAD is one of that PR's own commits
        elif git -C "$p" cat-file -e "${pr_head}^{commit}" 2>/dev/null &&
             git -C "$p" merge-base --is-ancestor "$head" "$pr_head" 2>/dev/null; then
          : # HEAD is simply behind the PR head
        else
          ahead=true
        fi
      fi
    fi

    local action reason
    if [ "$p" = "$SELF_WT" ]; then
      action=review; reason="this session's own worktree"
    elif [ "$fl" = "locked" ]; then
      action=review; reason="worktree is locked"
    elif [ "$fl" = "prunable" ] || [ "$exists" = "false" ]; then
      action=prune; reason="directory is gone — needs 'git worktree prune'"
    elif [ -z "$nwo" ]; then
      action=review; reason="no github.com origin — PR state unknown"
    elif [ -z "$pr_json" ]; then
      action=review; reason="GitHub lookup failed — PR state unknown"
    elif [ "$pr" = "null" ] || [ -z "$pr_state" ]; then
      action=review; reason="no pull request found for this branch/commit"
    elif [ "$pr_state" = "OPEN" ]; then
      action=keep; reason="PR is open"
    elif [ "$dirty" = "true" ]; then
      action=review; reason="PR is ${pr_state}, but there are uncommitted changes"
    elif [ "$ahead" = "true" ]; then
      action=review; reason="PR is ${pr_state}, but HEAD has commits the PR head does not"
    else
      action=remove; reason="PR is ${pr_state}"
    fi

    jq -c \
      --arg repo "$root" --arg nwo "${nwo:-}" --arg path "$p" --arg branch "$br" \
      --arg head "$head" --arg action "$action" --arg reason "$reason" \
      --argjson managed "$managed" --argjson dirty "$dirty" --argjson ahead "$ahead" \
      --argjson pr "${pr:-null}" \
      '. + [{repo:$repo, nwo:$nwo, path:$path, branch:$branch, head:$head,
             managed:$managed, dirty:$dirty, ahead:$ahead, action:$action,
             reason:$reason, pr:$pr}]' "$recs" > "$recs.tmp" && mv "$recs.tmp" "$recs"
  done

  jq -s '.[0] + .[1]' "$all_file" "$recs" > "$all_file.tmp" && mv "$all_file.tmp" "$all_file"
  rm -f "$recs"
}

render_table() {
  jq -r '
    def line:
      "  " + .path
      + (if .managed then "" else "   [outside .claude/worktrees]" end)
      + "\n      " + (if .branch == "" then "(detached " + (.head[0:9]) + ")" else .branch end)
      + (if .pr then
           "  ->  PR #" + (.pr.number|tostring) + " " + .pr.state
           + (if .pr.isDraft and .pr.state == "OPEN" then " (draft)" else "" end)
           + " — " + .pr.title
         else "  ->  no PR" end)
      + "\n      " + .reason;
    if length == 0 then "No worktrees found." else
      group_by(.action)
      | map({action: .[0].action, items: .})
      | sort_by(.action as $a | ["remove","prune","review","keep"] | index($a))
      | map(
          "## " + (.action | ascii_upcase) + " (" + (.items|length|tostring) + ")\n"
          + (.items | map(line) | join("\n"))
        )
      | join("\n\n")
    end
  ' "$1"
}

# ----------------------------------------------------------------- remove ---

remove() {
  local delete_branch=0 force=0 targets=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --delete-branch) delete_branch=1; shift ;;
      --force) force=1; shift ;;
      -*) die "unknown remove flag: $1" ;;
      *) targets+=("$1"); shift ;;
    esac
  done
  [ ${#targets[@]} -gt 0 ] || die "remove needs at least one worktree path"

  local t root br rc=0
  for t in "${targets[@]}"; do
    if [ "$t" = "$SELF_WT" ]; then
      printf 'SKIP  %s (this session is running in it)\n' "$t"; rc=1; continue
    fi
    root=$(main_root_of "$t" 2>/dev/null) || root=""
    if [ -z "$root" ]; then
      printf 'FAIL  %s (cannot resolve its repository)\n' "$t"; rc=1; continue
    fi
    br=$(git -C "$t" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    # Establish cleanliness BEFORE touching anything — it is the permission
    # slip for the fallback below, and a half-finished delete would forge it.
    local clean=0 st
    if st=$(git -C "$t" status --porcelain --ignore-submodules=none 2>/dev/null) && [ -z "$st" ]; then
      clean=1
    fi

    if [ $force -eq 1 ]; then
      git -C "$root" worktree remove --force "$t" >/dev/null 2>&1
    else
      git -C "$root" worktree remove "$t" >/dev/null 2>&1
    fi

    # git leaves the directory behind in two ways, both fine when the tree was
    # clean, because everything still on disk is then gitignored build output:
    #   * it deregisters the worktree but will not rmdir over node_modules,
    #     dist, .meteor/local, .env — the leftover is an orphan;
    #   * it refuses outright ("working trees containing submodules cannot be
    #     moved or removed") and leaves the worktree registered.
    if [ -d "$t" ]; then
      if [ $clean -eq 0 ] && [ $force -eq 0 ]; then
        printf 'FAIL  %s (not clean — left untouched)\n' "$t"; rc=1; continue
      fi
      # rm loses a race with Finder/watchman recreating .DS_Store underneath it
      # and reports "Directory not empty"; a second pass gets it.
      local try
      for try in 1 2 3 4 5; do
        [ -d "$t" ] || break
        find "$t" -name .DS_Store -delete 2>/dev/null
        rm -rf "$t" 2>/dev/null
      done
      git -C "$root" worktree prune >/dev/null 2>&1
      if [ -d "$t" ]; then
        printf 'FAIL  %s (could not delete the directory)\n' "$t"; rc=1; continue
      fi
      printf 'REMOVED  %s (cleared build artifacts)\n' "$t"
    else
      printf 'REMOVED  %s\n' "$t"
    fi
    if [ $delete_branch -eq 1 ] && [ -n "$br" ]; then
      if git -C "$root" branch -d "$br" >/dev/null 2>&1; then
        printf '         deleted branch %s\n' "$br"
      else
        printf '         kept branch %s (not fully merged — delete by hand if you mean it)\n' "$br"
      fi
    fi
  done
  return $rc
}

# ------------------------------------------------------------------ prune ---

prune() {
  [ $# -gt 0 ] || die "prune needs at least one repo path"
  local r root
  for r in "$@"; do
    root=$(main_root_of "$r" 2>/dev/null) || continue
    printf '%s\n' "$root"
    git -C "$root" worktree prune -v 2>&1 | sed 's/^/  /'
  done
}

# ------------------------------------------------------------------- main ---

command -v gh  >/dev/null 2>&1 || die "gh is required"
command -v jq  >/dev/null 2>&1 || die "jq is required"

cmd="${1:-}"; shift 2>/dev/null || true
case "$cmd" in
  scan)   scan "$@" ;;
  remove) remove "$@" ;;
  prune)  prune "$@" ;;
  *) die "usage: worktree-sweep.sh {scan|remove|prune} ..." ;;
esac
