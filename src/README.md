# GitHub → GitLab mirror scripts

This folder contains bash utilities that mirror **your GitHub repositories** to **GitLab** (code and optionally issues), using `git`, `curl`, and `jq`—no `gh` or GitLab CLI required.

## Scripts

| File | Role |
|------|------|
| `mirror_gemini.sh` | Earlier / alternate mirror flow with always-on issue sync and colored logs. |
| `mirror_superset.sh` | Full-featured mirror: persistent cache, optional issue sync, configurable APIs/hosts. |
| `mirror_consolidated.sh` | Same as **`mirror_superset.sh`**, plus **`--github-repo-list`** / **`MIRROR_GITHUB_REPO_LIST`** to choose GitHub `user/repos` query (`affiliation=owner` vs `type=owner`). |

Environment and flags are documented in the header comments of each script.

---

## Detailed comparison: `mirror_gemini.sh` vs `mirror_superset.sh`

| Area | `mirror_gemini.sh` | `mirror_superset.sh` |
|------|--------------------|----------------------|
| **Shell strictness** | `set -eo pipefail` (no `-u`) | `set -euo pipefail` |
| **GitHub listing** | `/user/repos?type=owner&...` | `/user/repos?affiliation=owner&...` (can differ slightly from `type=owner`) |
| **GitHub REST auth** | `Authorization: token …` | `Authorization: Bearer …` + `Accept` + `X-GitHub-Api-Version` |
| **GitLab REST auth** | `Authorization: Bearer …` | `PRIVATE-TOKEN: …` |
| **Hosts** | Hard-coded `api.github.com` / `gitlab.com` | `GITHUB_API`, `GITLAB_HOST` |
| **CLI** | `--dry-run`, `--force` only | `--dry-run`, `--force`, `--continue-on-error`, `--help`, user overrides, `--sync-issues`, `--sync-issue-comments`, namespace options |
| **Repo cache** | Temp bare clone per push, deleted on exit | Persistent `MIRROR_CACHE` mirror repos |
| **Remote compare** | `git ls-remote --heads` only (branches; **tags not compared**) | `git ls-remote --refs` filtered to **heads + tags**, sorted (full ref identity) |
| **Push** | `git push --all` + `--tags` | `push --prune` with explicit `+refs/heads/*` / `+refs/tags/*` (avoids GitHub `refs/pull/*` problems) |
| **Visibility** | New GitLab projects always **private** | **Public/private** from GitHub `private` flag |
| **Issues** | **Always** runs issue sync; idempotency by GitLab title `[GitHub Sync] Issue #N: …`; first 100 GitLab issues only in memory | **Optional** `--sync-issues`; idempotency via `${MIRROR_CACHE}/.issue-sync/<repo>.json`; optional **comment** sync |
| **Failure handling** | Stops on first GitLab create failure for a repo | `--continue-on-error` + exit summary |

### Features only in `mirror_gemini.sh`

1. **ANSI-colored** `[INFO]` / `[WARN]` / `[ERROR]` lines.
2. **`type=owner`** GitHub repo listing (vs `affiliation=owner`).
3. **Issue sync always on** (no flag).
4. **Different issue idempotency**: title prefix `[GitHub Sync] Issue #N:` and body prefix `*Original GitHub Reference: Issue #N*`.
5. **GitLab project create** via Bearer token + `jq` on the response (similar goal to superset, different headers).
6. **Ephemeral** `mktemp` working directory (no long-lived mirror cache).

### Features only in `mirror_superset.sh`

1. **`set -u`**, broader CLI, **`--help`**.
2. **Configurable** `GITHUB_API` / `GITLAB_HOST`.
3. **Persistent mirror cache** and **pruned** ref push (safer for GitHub → GitLab).
4. **Tags included** in `ls-remote` comparison (`mirror_gemini.sh` only compared **heads**, so **tag-only drift could be missed**).
5. **Optional** issue sync + **issue comments** + **JSON state file** idempotency.
6. **`--continue-on-error`**, GitLab **namespace_id** for new projects, **public/private** from GitHub.

---

## `mirror_consolidated.sh`

`mirror_consolidated.sh` is **`mirror_superset.sh` with one functional addition**: you can mirror the same **GitHub repo list** as `mirror_gemini.sh` (which uses `type=owner`) without giving up superset’s behavior elsewhere.

- **`--github-repo-list affiliation-owner`** (default) — `affiliation=owner` (superset default).
- **`--github-repo-list type-owner`** — `type=owner` (same filter as `mirror_gemini.sh`).

Initial mode is also set from **`MIRROR_GITHUB_REPO_LIST`** before the argument loop; **`--github-repo-list` overrides** when you pass it.

Examples:

```bash
bash mirror_consolidated.sh --sync-issues
```

```bash
bash mirror_consolidated.sh --github-repo-list type-owner --sync-issues
```

```bash
MIRROR_SYNC_ISSUES=1 MIRROR_GITHUB_REPO_LIST=type-owner bash mirror_consolidated.sh
```

---

## Requirements

- **bash**, **git**, **curl**, **jq**
- Tokens / users as documented in each script (typically `GITHUB_USER`, `GITHUB_TOKEN`, `GITLAB_USER`, `GITLAB_TOKEN`)

---

## Choosing a script

- Use **`mirror_superset.sh`** if you want the reference script with no extra options.
- Use **`mirror_consolidated.sh`** if you want superset behavior **and** the ability to switch GitHub listing between `affiliation=owner` and `type=owner`.
- Use **`mirror_gemini.sh`** only if you still need its exact legacy behavior (always-on issues, colored logs, Bearer GitLab API, ephemeral cache, etc.).
