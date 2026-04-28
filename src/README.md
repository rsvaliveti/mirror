# Bash scripts comparison

Here is a structured comparison of the five Bash scripts in this direcoty. 
They are all **GitHub → GitLab** mirroring utilities, but they differ sharply in 
age, safety, and behavior.

## Shared purpose

Each script lists **your GitHub repositories** (with variations on *which* repos), ensures a **matching project exists on GitLab**, and **pushes Git content** so GitLab tracks GitHub. They all assume **curl**, **git**, and **jq** are available.

---

## At a glance

| Aspect | `mirror_v0.sh` | `mirror_v1.sh` | `mirror_v2.sh` | `mirror_v3.sh` | `mirror_superset.sh` |
|--------|----------------|-----------------|-----------------|------------------|----------------------|
| **Lines** | ~74 | ~205 | ~239 | ~335 | ~402 |
| **Shebang / strict mode** | `#!/bin/bash`, no `set -e` | `#!/usr/bin/env bash`, strict **commented out** | `set -euo pipefail` | `set -euo pipefail` | `set -euo pipefail` |
| **GitHub auth** | Basic (`-u user:token`) | `Authorization: token` | Basic | Bearer + API version header | Bearer + API version header |
| **Repo listing** | `user/repos?type=owner&per_page=100` (no pagination) | `per_page=200`, no page loop | Paginated `affiliation=owner` | Paginated `affiliation=owner` | Paginated `affiliation=owner` |
| **Forks / archived** | All owned repos | All listed on GitHub side | **Skip** forks & archived | **Include** forks (owner) | **Include** forks |
| **GitLab target** | User path + `GITLAB_GROUP_ID` on create (inconsistent) | `GITLAB_NAMESPACE` + membership listing | Resolved `namespace_id` + user | Path under `GITLAB_USER` | Same + optional **explicit namespace id** |
| **“In sync” check** | REST: latest **commit SHA** on each side | `git ls-remote` + optional **merge-base** in temp repo | `ls-remote` on default branch + **merge-base** in mirror clone | `ls-remote` on **default branch** + bare cache + `merge-base` | **Full `ls-remote` ref map** (heads+tags), then cache + per-branch divergence |
| **Push style** | Always **`git push --mirror`** when SHAs differ | **`--mirror`** (or `--force` with `--mirror`) | Mixed: mirror clone, then branch FF or **`--mirror --force`** | Usually **one branch + tags**, not full mirror | **`refs/heads/*` + `refs/tags/*`** with `--prune`, optional `--force` |
| **Persistent cache** | No (clone per repo, `cd` in CWD) | `mktemp` only | Temp dirs + `trap` | **`MIRROR_CACHE`** bare repos | **`MIRROR_CACHE`** bare repos |
| **Dry run / force** | No | Yes | Yes | Yes | Yes |
| **Self-hosted GitLab** | `gitlab.com` only | `gitlab.com` only | `gitlab.com` only | **`GITLAB_HOST`** | **`GITLAB_HOST`** |

---

## `mirror_v0.sh` — baseline / prototype

- **Header** still says `mirror_all.sh`; behavior is “mirror everything when tips differ.”
- **Env check** loops over `REQUIRED_VARS` and exits if any is empty — clear and portable.
- **GitHub listing** is a single page (100 repos max); no pagination.
- **Sync decision** compares the **default branch’s latest commit** via **HTTP APIs**, not `git ls-remote`. That can disagree with what Git would consider the same ref in edge cases, but is simple.
- **GitLab create** uses `namespace_id=$GITLAB_GROUP_ID` while existence checks use `$GITLAB_USER%2F$repo` — if group id ≠ user namespace, creates and lookups can **diverge** (likely bug or leftover from a group migration).
- **Mirror path**: `git clone --mirror` into **`./$repo.git`** in the **current working directory**, `cd` in, push, `cd ..`, `rm -rf`. No `set -e`; a failure mid-loop can leave clutter or wrong `cwd`.
- **No** dry-run, force, fork filter, or divergence semantics — any SHA mismatch triggers a **full mirror push**.

---

## `mirror_v1.sh` — semantics-rich, less hardened

- **Defaults** embed `rsvaliveti` and echo user/namespace — convenient for you, **bad to commit** or share.
- **`set -euo pipefail` is disabled** — errors can slip through.
- **Two-way listing**: GitHub repo names **and** GitLab projects (`membership=true`). “Exists on GitLab” is `grep -qx` on **path**; that can miss naming/path quirks.
- **`compare_repos`**: discovers **default branch** per remote via `git ls-remote --symref`, then uses a temp repo and **`rev-list --left-right --count`** to classify **identical / behind / ahead / diverged**. GitLab **ahead** is skipped (does not overwrite GitLab-only commits).
- **Create project**: POST with only `name` and `visibility=private` — **no `namespace_id`**, so behavior depends on GitLab token’s **default namespace** (may not match `GITLAB_NAMESPACE` in URLs).
- **Mirror**: always `git clone --mirror` into **`mktemp -d`** — heavy for large monorepos, but no stale cache state.
- **`run` + `eval`** for dry-run — flexible but **`eval` on constructed strings** is a footgun if anything ever interpolates untrusted data.

---

## `mirror_v2.sh` — default-branch–centric, API-correct creates

- **Strict mode** and **`usage`** with **`--github-user` / `--gitlab-user`** overrides.
- **GitHub**: paginated; **`jq` filters out forks and archived** — narrower set than v3/superset.
- **GitLab**: **`get_gitlab_user_id`** + **`ensure_gitlab_project`** with **`namespace_id`** — aligns create with the intended user namespace.
- **`mirror_repo`**: uses GitHub’s **`.default_branch`** per repo; **`git_ls_remote`** for tips; if they differ, does a **fresh mirror clone**, **`fetch gitlab`**, then **`merge-base`** logic:
  - GitLab strictly behind → **`git push` one branch** (not full mirror).
  - Diverged → **`--force`** only if flag set; else skip with warning.
- **Dry-run**: skips some real work but still **fetches repo lists** (read-only).
- **Subshell note**: the big `(cd "$tmpdir" && ...)` block uses **`local`** inside compound commands — in Bash, **`local` in a subshell** can be surprising; worth a quick sanity test on your Bash version.

---

## `mirror_v3.sh` — cached mirrors, modern GitHub API, default branch + tags

- **Documentation** in comments is the clearest of the set (env, optional vars, behavior).
- **GitHub**: Bearer token, **`Accept` + `X-GitHub-Api-Version`**, **`affiliation=owner`** (includes **forks**).
- **Stores** `default_branch` and **`private`** in associative arrays; **skips** repos with **no commits** on default branch.
- **GitLab create**: JSON body, **visibility mirrors GitHub private/public**.
- **`MIRROR_CACHE`**: **persistent bare mirror** per repo; **`fetch --prune origin`**, **`gitlab-sync/$branch`** ref for GitLab tip, then **`merge-base --is-ancestor`** for fast-forward vs warn vs **`--force`**.
- Normal updates push **`refs/heads/$branch`** and **tags**, not **`--mirror`** — avoids blasting unrelated refs and matches “sync this product repo” use cases.
- **Errors on one repo** do not stop the loop (`sync_repo "$r" || true`) — good for batch resilience, bad if you need a non-zero exit on any failure.

---

## `mirror_superset.sh` — broadest surface area (multi-branch, PR-ref-safe)

- **Index** from GitHub: **name + private only** (no `default_branch` in the index — strategy is **whole-repo ref identity**).
- **Fast path**: **`ls_remote_refs_normalized`** on both remotes — if **sorted heads+tags** match exactly, **no local clone/fetch** (cheapest possible “already synced”).
- **Slow path**: same **`MIRROR_CACHE`** pattern as v3, but **`fetch gitlab` +refs/heads/*:refs/remotes/gitlab/*`** and **`branch_divergence_detected`** walks **every branch** that exists on both sides; any **non–fast-forward** divergence blocks push unless **`--force`**.
- **Critical difference from v0–v2 “mirror”**: pushes **`+refs/heads/*:refs/heads/*`** and **`+refs/tags/*:refs/tags/*`** with **`--prune`**, **not** `git push --mirror` — explicitly to avoid **`refs/pull/*`** (GitHub PR refs) that **GitLab often rejects**.
- **CLI**: **`--continue-on-error`**, **`--use-user-namespace-id`**, **`--gitlab-namespace-id`** for groups — superset of v3’s create behavior.
- **Exit codes**: can exit **1** after failures or first failure depending on flags — stricter than v3’s always-continue loop.

---

## Evolution narrative (how they relate)

1. **v0** → minimal automation: API tip comparison + full mirror, fragile around **pagination**, **cwd**, and **namespace_id** vs **user path**.
2. **v1** → introduces **relationship semantics** (ahead/behind/diverged) and **dry-run/force**, but weaker **strict mode**, **eval**, and **project creation** targeting.
3. **v2** → **production-shaped**: strict Bash, **paginated GitHub**, **correct GitLab namespace**, **default-branch** sync and **smarter push** than blind `--mirror`.
4. **v3** → adds **persistent cache**, **modern GitHub API**, **visibility parity**, **empty-repo skips**, and **default-branch + tags** workflow; still **single-branch–centric** for merge-base decisions after fetch.
5. **superset** → generalizes to **all branches**, **ls-remote identity short-circuit**, **safe refspec** (no PR refs), **GitLab host override**, **namespace/group** options, and **controlled failure handling**.

---

## Practical “which script when?”

- **Quickest throwaway / legacy**: v0 — only if repo count &lt; 100 and you accept full mirror and cwd side effects.
- **“Do not overwrite GitLab if it’s ahead”**: v1’s model is explicit (v3/superset focus on GitHub as source of truth for the branches they care about, with divergence warnings or force).
- **Personal mirrors, default branch, efficiency**: **v3** is a strong default: cache, API hygiene, clear logs.
- **Forks, many branches, GitLab groups, or GitHub PR refs matter**: **superset** is the most complete and the only one designed around **avoiding `refs/pull/*`** and **multi-branch divergence**.


