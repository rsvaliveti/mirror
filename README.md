# Mirror

Bash scripts to mirror **your GitHub content** to **GitLab**—repositories and gists—using `git`, `curl`, and `jq`. No `gh` or GitLab CLI required.

## What it does

### Repositories

For each GitHub repo you own (including your forks), the script compares GitHub and GitLab and acts accordingly:

- **Identical** (all branches and tags match) — no action
- **GitLab behind** — push missing commits
- **Diverged histories** — skip, or overwrite GitLab with `--force`
- **Missing on GitLab** — create the project and push

Additional behavior:

- Compares **all branches and tags**, not just the default branch
- Uses `git ls-remote` first to avoid unnecessary clones
- Paginates GitHub repo listing for any number of repos
- Syncs **visibility** (`public` / `private`) from GitHub on every run
- Optional **issue sync** (open/closed state; comments optional)
- **Dry-run** mode to preview operations
- Retries transient GitLab API errors; detailed error messages on failure

### Gists

`mirror_gists.sh` mirrors GitHub Gists (public and secret) to GitLab personal snippets, including file content and visibility.

## Quick start

Set required environment variables:

```bash
export GITHUB_USER=your-github-user
export GITHUB_TOKEN=ghp_...
export GITLAB_USER=your-gitlab-user
export GITLAB_TOKEN=glpat-...
```

Mirror repositories:

```bash
bash src/mirror_superset.sh
```

Mirror gists:

```bash
bash src/mirror_gists.sh
```

See [`src/README.md`](src/README.md) for all scripts, flags, environment variables, and examples.

## Design goals

- No dependence on `gh` or GitLab CLI
- Environment variables only for credentials (`GITHUB_USER`, `GITHUB_TOKEN`, `GITLAB_USER`, `GITLAB_TOKEN`); no SSH keys assumed
- Depends only on basic tools on Ubuntu: `bash`, `git`, `curl`, `jq`
- Fast and efficient: avoid unnecessary cloning and pushing
- Covers repos owned by a user, or forks initiated by the user
- Handles an arbitrary number of repositories via API pagination
- Handles all branches (and tags) at the source, not just `main`
- Dry-run support
- Optional issue migration from GitHub to GitLab
- Clear error messages to aid debugging

## Scripts

| Script | Purpose |
|--------|---------|
| [`src/mirror_superset.sh`](src/mirror_superset.sh) | **Recommended** — full-featured repo mirror |
| [`src/mirror_consolidated.sh`](src/mirror_consolidated.sh) | Same as superset, plus configurable GitHub repo listing |
| [`src/mirror_gists.sh`](src/mirror_gists.sh) | Gists → GitLab snippets |
| [`src/mirror_gemini.sh`](src/mirror_gemini.sh) | Legacy repo mirror (alternate behavior) |

## Directory structure

- **`src/`** — mirror scripts and [`src/README.md`](src/README.md) (detailed comparison, flags, examples)
- **`README.md`** — this file (project overview)
