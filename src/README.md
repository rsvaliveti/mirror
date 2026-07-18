# GitHub → GitLab mirror scripts

This folder contains bash utilities that mirror **your GitHub content** to **GitLab** using `git`, `curl`, and `jq`—no `gh` or GitLab CLI required.

| Script | What it mirrors |
|--------|-----------------|
| `mirror_superset.sh` | Repositories (code; optional issues) |
| `mirror_consolidated.sh` | Same as `mirror_superset.sh`, plus configurable GitHub repo listing |
| `mirror_gemini.sh` | Repositories (legacy alternate flow) |
| `mirror_gists.sh` | Gists → GitLab personal snippets |

## Scripts overview

| File | Role |
|------|------|
| `mirror_superset.sh` | Full-featured repo mirror: persistent cache, optional issue sync, visibility sync, API retries, configurable hosts. |
| `mirror_consolidated.sh` | Same as **`mirror_superset.sh`**, plus **`--github-repo-list`** / **`MIRROR_GITHUB_REPO_LIST`** to choose the GitHub `user/repos` query (`affiliation=owner` vs `type=owner`). |
| `mirror_gemini.sh` | Earlier / alternate repo mirror with always-on issue sync and colored logs. |
| `mirror_gists.sh` | Mirrors GitHub Gists to GitLab personal snippets (content + visibility). |

CLI flags and environment variables are documented in the header comment of each script.

---

## Shared environment variables

All scripts require:

| Variable | Purpose |
|----------|---------|
| `GITHUB_USER` | GitHub username |
| `GITHUB_TOKEN` | GitHub personal access token |
| `GITLAB_USER` | GitLab username (path segment in clone URLs) |
| `GITLAB_TOKEN` | GitLab personal access token |

Common optional variables (repo scripts and gists):

| Variable | Default | Purpose |
|----------|---------|---------|
| `GITHUB_API` | `https://api.github.com` | GitHub API base URL |
| `GITLAB_HOST` | `https://gitlab.com` | GitLab host (repo scripts and gists) |
| `GITLAB_API_RETRIES` | `3` | Retries on transient GitLab HTTP errors (`000`, `429`, `502`, `503`, `504`) |
| `GITLAB_API_RETRY_DELAY` | `2` | Initial retry delay in seconds (doubles each retry) |

Repo scripts (`mirror_superset.sh`, `mirror_consolidated.sh`) additionally support:

| Variable | Default | Purpose |
|----------|---------|---------|
| `MIRROR_CACHE` | `~/.cache/mirror-github-to-gitlab` | Persistent bare-repo cache |
| `MIRROR_SYNC_ISSUES` | `0` | Set to `1` to enable issue sync (same as `--sync-issues`) |
| `MIRROR_SYNC_ISSUE_COMMENTS` | `0` | Set to `1` to copy issue comments (same as `--sync-issue-comments`) |

`mirror_consolidated.sh` also supports `MIRROR_GITHUB_REPO_LIST` (`affiliation-owner` or `type-owner`).

---

## Repo mirroring: `mirror_superset.sh` / `mirror_consolidated.sh`

### Behavior

1. List GitHub repos you own (`affiliation=owner` by default).
2. For each repo, compare branch/tag refs with GitLab via `git ls-remote` (no clone if identical).
3. Create missing GitLab projects, push changed refs via a persistent bare cache, optionally sync issues.
4. Sync **visibility** (`public` / `private`) from GitHub on every run for existing projects; set on create for new projects.

### CLI flags (both repo scripts)

| Flag | Description |
|------|-------------|
| `--dry-run` | Log operations only; no API writes or git fetch/push |
| `--force` | Force-push branches+tags when histories have diverged |
| `--continue-on-error` | Process all repos; exit 1 if any failed |
| `--use-user-namespace-id` | Resolve GitLab user id and pass `namespace_id` when creating projects |
| `--gitlab-namespace-id ID` | Use a specific namespace id for new projects (e.g. a group) |
| `--github-user USER` | Override `GITHUB_USER` |
| `--gitlab-user USER` | Override `GITLAB_USER` |
| `--sync-issues` | Copy GitHub issues (not PRs) into GitLab |
| `--sync-issue-comments` | With `--sync-issues`, copy comments as GitLab notes on first create |
| `--help` | Show usage |

`mirror_consolidated.sh` adds:

| Flag | Description |
|------|-------------|
| `--github-repo-list MODE` | `affiliation-owner` (default) or `type-owner` |

### Examples

```bash
bash mirror_superset.sh --sync-issues
```

```bash
bash mirror_consolidated.sh --github-repo-list type-owner --continue-on-error
```

```bash
GITLAB_API_RETRIES=5 MIRROR_SYNC_ISSUES=1 bash mirror_superset.sh
```

### Resilience (superset + consolidated)

- GitLab GET/POST/PUT calls retry on transient errors.
- Failed API responses include the GitLab error body in logs.
- If project create returns HTTP 400 but the project already exists, the script continues instead of failing.

---

## `mirror_consolidated.sh`

`mirror_consolidated.sh` is **`mirror_superset.sh` with one functional addition**: you can mirror the same **GitHub repo list** as `mirror_gemini.sh` (which uses `type=owner`) without giving up superset's behavior elsewhere.

- **`--github-repo-list affiliation-owner`** (default) — `affiliation=owner` (superset default).
- **`--github-repo-list type-owner`** — `type=owner` (same filter as `mirror_gemini.sh`).

Initial mode is also set from **`MIRROR_GITHUB_REPO_LIST`** before the argument loop; **`--github-repo-list` overrides** when you pass it.

---

## Gist mirroring: `mirror_gists.sh`

Mirrors all Gists for the authenticated GitHub user (public and secret) to **GitLab personal snippets**.

### Behavior

1. Fetch all GitHub gists (`GET /gists`).
2. Fetch existing GitLab snippets once.
3. For each gist, match an existing snippet by description (`Synced from GitHub Gist <id>`) with title as fallback.
4. **Create** new snippets or **update** existing ones (content, title, description, visibility).
5. On update, GitLab requires `files[].action` per file (`create`, `update`, or `delete`); the script builds these by diffing against the current snippet.

### Visibility

GitHub gist `public: true` → GitLab `public`; otherwise `private`. Synced on both create and update.

### Example

```bash
bash mirror_gists.sh
```

```bash
GITLAB_HOST=https://gitlab.example.com bash mirror_gists.sh
```

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
| **Visibility** | New GitLab projects always **private** | **Public/private** from GitHub `private` flag; **synced on every run** for existing projects |
| **Issues** | **Always** runs issue sync; idempotency by GitLab title `[GitHub Sync] Issue #N: …`; first 100 GitLab issues only in memory | **Optional** `--sync-issues`; idempotency via `${MIRROR_CACHE}/.issue-sync/<repo>.json`; optional **comment** sync |
| **API retries** | None | Retries with backoff; detailed error bodies on failure |
| **Failure handling** | Stops on first GitLab create failure for a repo | `--continue-on-error` + exit summary |

### Features only in `mirror_gemini.sh`

1. **ANSI-colored** `[INFO]` / `[WARN]` / `[ERROR]` lines.
2. **`type=owner`** GitHub repo listing (vs `affiliation=owner`).
3. **Issue sync always on** (no flag).
4. **Different issue idempotency**: title prefix `[GitHub Sync] Issue #N:` and body prefix `*Original GitHub Reference: Issue #N*`.
5. **GitLab project create** via Bearer token + `jq` on the response (similar goal to superset, different headers).
6. **Ephemeral** `mktemp` working directory (no long-lived mirror cache).

### Features only in `mirror_superset.sh` (and `mirror_consolidated.sh`)

1. **`set -u`**, broader CLI, **`--help`**.
2. **Configurable** `GITHUB_API` / `GITLAB_HOST`.
3. **Persistent mirror cache** and **pruned** ref push (safer for GitHub → GitLab).
4. **Tags included** in `ls-remote` comparison (`mirror_gemini.sh` only compared **heads**, so **tag-only drift could be missed**).
5. **Optional** issue sync + **issue comments** + **JSON state file** idempotency.
6. **`--continue-on-error`**, GitLab **namespace_id** for new projects, **public/private** from GitHub (create + ongoing sync).
7. **GitLab API retries** with exponential backoff; create treats HTTP 400 as success when the project already exists.

---

## Requirements

- **bash**, **git**, **curl**, **jq**
- `mirror_gists.sh` does not use `git`; the repo scripts do.

---

## Choosing a script

| Goal | Script |
|------|--------|
| Mirror repos (recommended) | `mirror_superset.sh` |
| Mirror repos + switch GitHub listing mode | `mirror_consolidated.sh` |
| Mirror gists | `mirror_gists.sh` |
| Legacy repo mirror behavior | `mirror_gemini.sh` |

Typical workflow: run a repo script for repositories, then `mirror_gists.sh` for gists.
