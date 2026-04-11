#!/usr/bin/env bash
# Mirror GitHub repos (owned by you, including your forks) to GitLab.
# Requires: git, curl, jq. Env: GITHUB_USER, GITHUB_TOKEN, GITLAB_USER, GITLAB_TOKEN
# Optional: GITLAB_HOST (default https://gitlab.com), MIRROR_CACHE (bare repo cache dir)

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: mirror-github-to-gitlab.sh [--dry-run] [--force]

  --dry-run   Print planned operations; no API writes, no git push/fetch.
  --force     If GitHub and GitLab have diverged, force-push GitLab to match GitHub.

Environment (required):
  GITHUB_USER    GitHub username used in clone URLs (owner of listed repos)
  GITHUB_TOKEN   GitHub personal access token (repo scope for private repos)
  GITLAB_USER    GitLab username or group path segment for target namespace
  GITLAB_TOKEN   GitLab personal access token (api, write_repository)

Optional:
  GITLAB_HOST    Base URL, default https://gitlab.com
  MIRROR_CACHE   Directory for bare git mirrors, default ~/.cache/mirror-github-to-gitlab

Notes:
  - Lists repos via GitHub API with affiliation=owner (your repos and your forks).
  - Syncs the GitHub default branch to the same branch name on GitLab.
  - Skips empty GitHub repos (no commits on the default branch).
  - Uses a persistent bare cache per repo; incremental fetch after the first run.
EOF
}

DRY_RUN=0
FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --force)   FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

for v in GITHUB_USER GITHUB_TOKEN GITLAB_USER GITLAB_TOKEN; do
  if [[ -z "${!v:-}" ]]; then
    echo "Missing required environment variable: $v" >&2
    exit 1
  fi
done

GITHUB_API="${GITHUB_API:-https://api.github.com}"
GITLAB_HOST="${GITLAB_HOST:-https://gitlab.com}"
GITLAB_HOST="${GITLAB_HOST%/}"
gitlab_host_plain="${GITLAB_HOST#https://}"
gitlab_host_plain="${gitlab_host_plain#http://}"
gitlab_host_plain="${gitlab_host_plain%/}"

GITLAB_API="$GITLAB_HOST/api/v4"
MIRROR_CACHE="${MIRROR_CACHE:-$HOME/.cache/mirror-github-to-gitlab}"

declare -A REPO_DEFAULT_BRANCH=()
declare -A REPO_GITHUB_PRIVATE=()

github_remote_url() {
  local repo="$1"
  printf 'https://x-access-token:%s@github.com/%s/%s.git' "$GITHUB_TOKEN" "$GITHUB_USER" "$repo"
}

gitlab_remote_url() {
  local repo="$1"
  printf 'https://oauth2:%s@%s/%s/%s.git' "$GITLAB_TOKEN" "$gitlab_host_plain" "$GITLAB_USER" "$repo"
}

# URL-encode path for GitLab project API (namespace/project)
gitlab_project_path_encoded() {
  local repo="$1"
  jq -rn --arg p "${GITLAB_USER}/${repo}" '@uri "\($p)"'
}

gh_curl() {
  curl -sS -f -H "Authorization: Bearer ${GITHUB_TOKEN}" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "$@"
}

log() { printf '%s\n' "$*"; }

dry() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] %s\n' "$*"
  fi
}

# Paginated: one TSV row per repo: name, default_branch, private
fetch_github_repo_index() {
  local page=1
  while true; do
    local url="${GITHUB_API}/user/repos?affiliation=owner&per_page=100&page=${page}"
    local json
    json=$(gh_curl "$url") || return 1
    local count
    count=$(echo "$json" | jq 'length')
    if [[ "$count" -eq 0 ]]; then
      break
    fi
    echo "$json" | jq -r '.[] | [.name, (.default_branch // ""), (.private|tostring)] | @tsv'
    page=$((page + 1))
  done
}

gitlab_project_http_code() {
  local repo="$1"
  local enc
  enc=$(gitlab_project_path_encoded "$repo")
  curl -sS -o /dev/null -w '%{http_code}' -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" "${GITLAB_API}/projects/${enc}"
}

gitlab_project_exists() {
  local repo="$1"
  local code
  code=$(gitlab_project_http_code "$repo")
  [[ "$code" == "200" ]]
}

gitlab_create_project() {
  local repo="$1"
  local is_private="$2"
  local visibility="public"
  [[ "$is_private" == "true" ]] && visibility="private"
  local body
  body=$(jq -n \
    --arg name "$repo" \
    --arg path "$repo" \
    --arg visibility "$visibility" \
    '{name: $name, path: $path, visibility: $visibility}')
  curl -sS -f -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" -X POST "${GITLAB_API}/projects" \
    -H 'Content-Type: application/json' \
    -d "$body" >/dev/null
}

# ls-remote SHA for ref; prints full SHA or empty
remote_branch_sha() {
  local url="$1"
  local ref="$2"
  git ls-remote "$url" "$ref" 2>/dev/null | awk '{print $1; exit}'
}

ensure_bare_mirror() {
  local repo="$1"
  local gh_url
  gh_url=$(github_remote_url "$repo")
  local dir="${MIRROR_CACHE}/${repo}.git"
  if [[ ! -d "$dir" ]]; then
    dry "git clone --mirror <github-url> -> ${dir}"
    if [[ "$DRY_RUN" -eq 0 ]]; then
      mkdir -p "$MIRROR_CACHE"
      git clone --mirror "$gh_url" "$dir"
    fi
  fi
}

configure_gitlab_remote() {
  local repo="$1"
  local dir="${MIRROR_CACHE}/${repo}.git"
  local gl_url
  gl_url=$(gitlab_remote_url "$repo")
  if [[ "$DRY_RUN" -eq 1 ]]; then
    dry "git -C ${dir} remote add|set-url gitlab <gitlab-url>"
    return 0
  fi
  if git -C "$dir" remote get-url gitlab &>/dev/null; then
    git -C "$dir" remote set-url gitlab "$gl_url"
  else
    git -C "$dir" remote add gitlab "$gl_url"
  fi
}

fetch_github() {
  local repo="$1"
  local dir="${MIRROR_CACHE}/${repo}.git"
  dry "git -C ${dir} fetch --prune origin"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    git -C "$dir" fetch --prune origin
  fi
}

# Fetch GitLab tip into refs/remotes/gitlab-sync/<branch> (best-effort).
fetch_gitlab_sync_ref() {
  local repo="$1"
  local branch="$2"
  local dir="${MIRROR_CACHE}/${repo}.git"
  dry "git -C ${dir} fetch gitlab +refs/heads/${branch}:refs/remotes/gitlab-sync/${branch}"
  if [[ "$DRY_RUN" -eq 0 ]]; then
    git -C "$dir" fetch gitlab "+refs/heads/${branch}:refs/remotes/gitlab-sync/${branch}" 2>/dev/null || true
  fi
}

sync_repo() {
  local repo="$1"
  local branch="${REPO_DEFAULT_BRANCH[$repo]:-}"
  local gh_private="${REPO_GITHUB_PRIVATE[$repo]:-false}"

  if [[ -z "$branch" ]]; then
    log "SKIP ${repo}: no default branch in GitHub listing"
    return 0
  fi

  local gh_url gl_url
  gh_url=$(github_remote_url "$repo")
  gl_url=$(gitlab_remote_url "$repo")

  local gh_sha gl_sha
  gh_sha=$(remote_branch_sha "$gh_url" "refs/heads/${branch}")
  if [[ -z "$gh_sha" ]]; then
    log "SKIP ${repo}: empty or missing branch on GitHub (${branch})"
    return 0
  fi

  local exists=0
  if gitlab_project_exists "$repo"; then
    exists=1
  fi

  if [[ "$exists" -eq 0 ]]; then
    dry "POST ${GITLAB_API}/projects (create ${GITLAB_USER}/${repo}, visibility matching GitHub private=${gh_private})"
    log "CREATE GitLab project ${GITLAB_USER}/${repo}"
    if [[ "$DRY_RUN" -eq 0 ]]; then
      gitlab_create_project "$repo" "$gh_private" || {
        log "ERROR ${repo}: failed to create GitLab project"
        return 1
      }
    fi
  fi

  gl_sha=$(remote_branch_sha "$gl_url" "refs/heads/${branch}" || true)

  if [[ -n "$gl_sha" && "$gl_sha" == "$gh_sha" ]]; then
    log "OK ${repo}: in sync (${branch}=${gh_sha:0:7})"
    return 0
  fi

  ensure_bare_mirror "$repo"
  configure_gitlab_remote "$repo"
  fetch_github "$repo"
  fetch_gitlab_sync_ref "$repo" "$branch"

  local dir="${MIRROR_CACHE}/${repo}.git"
  local ref_gh="refs/heads/${branch}"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    if [[ -z "$gl_sha" ]]; then
      dry "git -C ${dir} push gitlab ${ref_gh}:${ref_gh} && git push gitlab --tags"
    else
      dry "git -C ${dir} fetch gitlab; merge-base check; push or git push --force"
    fi
    log "PLAN ${repo}: would update GitLab (${gl_sha:-no-ref} -> ${gh_sha:0:7})"
    return 0
  fi

  if [[ ! -d "$dir" ]]; then
    log "ERROR ${repo}: bare mirror missing after setup"
    return 1
  fi

  git -C "$dir" rev-parse --verify "${branch}^{commit}" &>/dev/null || {
    log "ERROR ${repo}: branch ${branch} not in mirror after fetch"
    return 1
  }

  local gh_tip gl_tip
  gh_tip=$(git -C "$dir" rev-parse "$branch")
  gl_tip=""
  if git -C "$dir" rev-parse --verify "gitlab-sync/${branch}^{commit}" &>/dev/null; then
    gl_tip=$(git -C "$dir" rev-parse "gitlab-sync/${branch}")
  fi

  if [[ -z "$gl_tip" ]]; then
    log "PUSH ${repo}: publish branch ${branch} to GitLab (${gh_tip:0:7})"
    git -C "$dir" push gitlab "${ref_gh}:${ref_gh}"
    git -C "$dir" push gitlab --tags 2>/dev/null || true
    return 0
  fi

  if [[ "$gl_tip" == "$gh_tip" ]]; then
    log "OK ${repo}: in sync after fetch (${branch}=${gh_tip:0:7})"
    return 0
  fi

  if git -C "$dir" merge-base --is-ancestor "$gl_tip" "$gh_tip" 2>/dev/null; then
    log "PUSH ${repo}: fast-forward GitLab ${branch} (${gl_tip:0:7}..${gh_tip:0:7})"
    git -C "$dir" push gitlab "${ref_gh}:${ref_gh}"
    git -C "$dir" push gitlab --tags 2>/dev/null || true
    return 0
  fi

  if [[ "$FORCE" -eq 1 ]]; then
    log "FORCE ${repo}: overwriting GitLab ${branch} with GitHub (${gl_tip:0:7} <- ${gh_tip:0:7})"
    git -C "$dir" push --force gitlab "${ref_gh}:${ref_gh}"
    git -C "$dir" push gitlab --tags --force 2>/dev/null || true
    return 0
  fi

  log "WARN ${repo}: diverged (GitLab ${gl_tip:0:7} vs GitHub ${gh_tip:0:7}). Re-run with --force to overwrite GitLab."
  return 0
}

mkdir -p "$MIRROR_CACHE"
idx="${MIRROR_CACHE}/.github-repo-index.tsv.tmp.$$"
if ! fetch_github_repo_index >"$idx"; then
  rm -f "$idx"
  log "Failed to list GitHub repositories (check GITHUB_TOKEN and network)."
  exit 1
fi

while IFS=$'\t' read -r name branch priv; do
  [[ -z "${name:-}" ]] && continue
  REPO_DEFAULT_BRANCH["$name"]="$branch"
  REPO_GITHUB_PRIVATE["$name"]="$priv"
done <"$idx"
rm -f "$idx"

repo_names=("${!REPO_DEFAULT_BRANCH[@]}")
if [[ ${#repo_names[@]} -eq 0 ]]; then
  log "No repositories returned from GitHub (check token and affiliation=owner)."
  exit 0
fi

IFS=$'\n' sorted_names=($(printf '%s\n' "${repo_names[@]}" | sort))
unset IFS

log "Found ${#sorted_names[@]} GitHub repo(s) (owner affiliation)."
for r in "${sorted_names[@]}"; do
  sync_repo "$r" || true
done
log "Done."
