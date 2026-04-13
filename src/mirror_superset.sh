#!/usr/bin/env bash
# Sync GitHub -> GitLab for repos you own (including your forks). No gh/gitlab CLI.
# Tools: bash, git, curl, jq (wget available on Ubuntu but unused here).
#
# Env (required): GITHUB_USER, GITHUB_TOKEN, GITLAB_USER, GITLAB_TOKEN
# Optional: GITHUB_API, GITLAB_HOST (default https://gitlab.com),
#           MIRROR_CACHE (default ~/.cache/mirror-github-to-gitlab)
#
# Compare GitHub vs GitLab with git ls-remote first (no local clone if identical).
# If refs differ: use persistent bare cache, fetch GitHub + GitLab branch tips, classify
# with merge-base, then push branches+tags to GitLab (not full --mirror: avoids refs/pull/*).

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: mirror_superset.sh [--dry-run] [--force] [--continue-on-error]
          [--use-user-namespace-id | --gitlab-namespace-id ID]
          [--github-user USER] [--gitlab-user USER]

  --dry-run                 Log operations; no POST /projects, no git fetch/push.
  --force                   If any shared branch diverged, git push --mirror --force.
  --continue-on-error       Process all repos; exit 1 if any repo failed (default:
                            stop on first failure).
  --use-user-namespace-id   Resolve GitLab user id via API (v2-style) and pass
                            namespace_id when creating projects (personal namespace).
  --gitlab-namespace-id ID  Use this numeric namespace id for new projects (e.g. group).
                            Mutually exclusive with --use-user-namespace-id.
  --github-user             Override GITHUB_USER.
  --gitlab-user             Override GITLAB_USER (path segment in clone URL).

Lists GitHub repos with affiliation=owner (your repos and forks you own).
When a push runs, syncs all branches and tags (not git push --mirror, to avoid GitHub PR refs).

Environment: GITHUB_USER, GITHUB_TOKEN, GITLAB_USER, GITLAB_TOKEN
EOF
}

DRY_RUN=0
FORCE=0
CONTINUE_ON_ERROR=0
USE_USER_NAMESPACE_LOOKUP=0
EXPLICIT_GITLAB_NAMESPACE_ID=""
OVERRIDE_GH_USER=""
OVERRIDE_GL_USER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --force) FORCE=1 ;;
    --continue-on-error) CONTINUE_ON_ERROR=1 ;;
    --use-user-namespace-id) USE_USER_NAMESPACE_LOOKUP=1 ;;
    --gitlab-namespace-id)
      EXPLICIT_GITLAB_NAMESPACE_ID="$2"
      shift
      ;;
    --github-user) OVERRIDE_GH_USER="$2"; shift ;;
    --gitlab-user) OVERRIDE_GL_USER="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"
: "${GITLAB_TOKEN:?GITLAB_TOKEN is required}"
GITHUB_USER="${OVERRIDE_GH_USER:-${GITHUB_USER:?GITHUB_USER is required}}"
GITLAB_USER="${OVERRIDE_GL_USER:-${GITLAB_USER:?GITLAB_USER is required}}"

GITHUB_API="${GITHUB_API:-https://api.github.com}"
GITLAB_HOST="${GITLAB_HOST:-https://gitlab.com}"
GITLAB_HOST="${GITLAB_HOST%/}"
gitlab_host_plain="${GITLAB_HOST#https://}"
gitlab_host_plain="${gitlab_host_plain#http://}"
gitlab_host_plain="${gitlab_host_plain%/}"
GITLAB_API="${GITLAB_HOST}/api/v4"
MIRROR_CACHE="${MIRROR_CACHE:-$HOME/.cache/mirror-github-to-gitlab}"

# Set when --gitlab-namespace-id or successful --use-user-namespace-id lookup.
GITLAB_NAMESPACE_ID=""

declare -A REPO_PRIVATE=()

log()   { printf '%s\n' "$*"; }
warn()  { printf '[WARN] %s\n' "$*" >&2; }
error() { printf '[ERROR] %s\n' "$*" >&2; }
dry()   { [[ "$DRY_RUN" -eq 1 ]] && printf '[dry-run] %s\n' "$*"; }

if [[ -n "$EXPLICIT_GITLAB_NAMESPACE_ID" && "$USE_USER_NAMESPACE_LOOKUP" -eq 1 ]]; then
  error "Use only one of --gitlab-namespace-id and --use-user-namespace-id."
  exit 1
fi
if [[ -n "$EXPLICIT_GITLAB_NAMESPACE_ID" ]] && ! [[ "$EXPLICIT_GITLAB_NAMESPACE_ID" =~ ^[0-9]+$ ]]; then
  error "--gitlab-namespace-id must be a non-negative integer."
  exit 1
fi

gh_curl() {
  curl -sS -f -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" "$@"
}

gitlab_curl_get() {
  curl -sS -f -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" "$@"
}

resolve_gitlab_user_namespace_id() {
  local enc json id
  enc=$(jq -rn --arg u "${GITLAB_USER}" '@uri "\($u)"')
  json=$(gitlab_curl_get "${GITLAB_API}/users?username=${enc}") || {
    error "GitLab user lookup failed (network or API error) for username=${GITLAB_USER}."
    return 1
  }
  id=$(printf '%s\n' "$json" | jq -r '.[0].id // empty')
  if [[ -z "$id" ]]; then
    error "GitLab user '${GITLAB_USER}' not found (GET /users?username=)."
    return 1
  fi
  GITLAB_NAMESPACE_ID="$id"
  log "Resolved GitLab user namespace_id=${GITLAB_NAMESPACE_ID} for ${GITLAB_USER}."
}

gitlab_project_path_encoded() {
  local repo="$1"
  jq -rn --arg p "${GITLAB_USER}/${repo}" '@uri "\($p)"'
}

github_remote_url() {
  local repo="$1"
  printf 'https://x-access-token:%s@github.com/%s/%s.git' "$GITHUB_TOKEN" "$GITHUB_USER" "$repo"
}

gitlab_remote_url() {
  local repo="$1"
  printf 'https://oauth2:%s@%s/%s/%s.git' "$GITLAB_TOKEN" "$gitlab_host_plain" "$GITLAB_USER" "$repo"
}

# Branches + tags only, sorted by ref name (identity check without cloning).
ls_remote_refs_normalized() {
  local url="$1"
  git ls-remote --refs "$url" 2>/dev/null \
    | awk '/\trefs\/(heads|tags)\// {print}' \
    | LC_ALL=C sort -k2
}

fetch_github_repo_index() {
  local page=1
  while true; do
    local url="${GITHUB_API}/user/repos?affiliation=owner&per_page=100&page=${page}"
    local json
    json=$(gh_curl "$url") || return 1
    local count
    count=$(echo "$json" | jq 'length')
    [[ "$count" -eq 0 ]] && break
    echo "$json" | jq -r '.[] | [.name, (.private|tostring)] | @tsv'
    [[ "$count" -lt 100 ]] && break
    page=$((page + 1))
  done
}

gitlab_project_http_code() {
  local repo="$1"
  local enc
  enc=$(gitlab_project_path_encoded "$repo")
  curl -sS -o /dev/null -w '%{http_code}' -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "${GITLAB_API}/projects/${enc}" 2>/dev/null || printf '000'
}

gitlab_create_project() {
  local repo="$1"
  local is_private="$2"
  local visibility="public"
  [[ "$is_private" == "true" ]] && visibility="private"
  local body
  if [[ -n "${GITLAB_NAMESPACE_ID}" ]]; then
    body=$(jq -n \
      --arg name "$repo" \
      --arg path "$repo" \
      --arg visibility "$visibility" \
      --argjson namespace_id "${GITLAB_NAMESPACE_ID}" \
      '{name: $name, path: $path, visibility: $visibility, namespace_id: $namespace_id}')
    dry "curl -X POST ${GITLAB_API}/projects (JSON create ${GITLAB_USER}/${repo}, visibility=${visibility}, namespace_id=${GITLAB_NAMESPACE_ID})"
  else
    body=$(jq -n \
      --arg name "$repo" \
      --arg path "$repo" \
      --arg visibility "$visibility" \
      '{name: $name, path: $path, visibility: $visibility}')
    dry "curl -X POST ${GITLAB_API}/projects (JSON create ${GITLAB_USER}/${repo}, visibility=${visibility})"
  fi
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  curl -sS -f -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" -X POST "${GITLAB_API}/projects" \
    -H 'Content-Type: application/json' -d "$body" >/dev/null \
    || {
      error "GitLab API: failed to create project '${repo}' (${GITLAB_USER}/${repo})."
      return 1
    }
}

configure_gitlab_remote() {
  local dir="$1"
  local gl_url="$2"
  dry "git -C ${dir} remote add|set-url gitlab <gitlab-url>"
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  if git -C "$dir" remote get-url gitlab &>/dev/null; then
    git -C "$dir" remote set-url gitlab "$gl_url"
  else
    git -C "$dir" remote add gitlab "$gl_url"
  fi
}

# git push --mirror also pushes GitHub PR refs (refs/pull/*), which GitLab rejects
# as hidden/forbidden. Push only branches and tags; --prune drops removed branches on GitLab.
push_gitlab_heads_and_tags() {
  local dir="$1"
  shift
  git -C "$dir" push --prune "$@" gitlab \
    "+refs/heads/*:refs/heads/*" \
    "+refs/tags/*:refs/tags/*"
}

# 0 = diverged on at least one shared branch (GitLab tip not ancestor of GitHub tip).
branch_divergence_detected() {
  local dir="$1"
  local ref bn gl_sha gh_sha
  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    bn="${ref#refs/heads/}"
    gh_sha=$(git -C "$dir" rev-parse "$ref^{commit}" 2>/dev/null) || continue
    if git -C "$dir" rev-parse --verify "refs/remotes/gitlab/${bn}^{commit}" &>/dev/null; then
      gl_sha=$(git -C "$dir" rev-parse "refs/remotes/gitlab/${bn}^{commit}" 2>/dev/null) || continue
    else
      continue
    fi
    [[ "$gh_sha" == "$gl_sha" ]] && continue
    if git -C "$dir" merge-base --is-ancestor "$gl_sha" "$gh_sha" 2>/dev/null; then
      continue
    fi
    return 0
  done < <(git -C "$dir" for-each-ref --format='%(refname)' refs/heads)
  return 1
}

sync_repo() {
  local repo="$1"
  local is_private="${REPO_PRIVATE[$repo]:-false}"
  local gh_url gl_url dir
  gh_url=$(github_remote_url "$repo")
  gl_url=$(gitlab_remote_url "$repo")
  dir="${MIRROR_CACHE}/${repo}.git"

  log "=== ${repo} ==="

  local gh_refs gl_code gl_refs
  gh_refs=$(ls_remote_refs_normalized "$gh_url" || true)
  if [[ -z "$gh_refs" ]]; then
    warn "${repo}: no refs from GitHub (empty or unreachable), skip"
    return 0
  fi

  gl_code=$(gitlab_project_http_code "$repo")
  if [[ "$gl_code" == "000" ]]; then
    error "${repo}: could not reach GitLab API or project URL (HTTP ${gl_code})."
    return 1
  fi

  if [[ "$gl_code" != "200" ]]; then
    log "MISSING ${repo}: GitLab project not found (HTTP ${gl_code})"
    dry "gitlab_create_project ${repo}"
    dry "mkdir -p ${MIRROR_CACHE}"
    dry "git clone --mirror <github-url> ${dir}"
    dry "git -C ${dir} remote add gitlab <gitlab-url>"
    dry "git -C ${dir} fetch --prune origin"
    dry "git -C ${dir} push --prune gitlab +refs/heads/*:refs/heads/* +refs/tags/*:refs/tags/*"
    [[ "$DRY_RUN" -eq 1 ]] && return 0

    gitlab_create_project "$repo" "$is_private" || return 1
    mkdir -p "$MIRROR_CACHE"
    if [[ ! -d "$dir" ]]; then
      git clone --mirror "$gh_url" "$dir" || {
        error "${repo}: git clone --mirror from GitHub failed."
        return 1
      }
    fi
    configure_gitlab_remote "$dir" "$gl_url"
    git -C "$dir" fetch --prune origin || {
      error "${repo}: git fetch --prune origin failed."
      return 1
    }
    log "PUSH ${repo}: initial push branches+tags to GitLab (new GitLab project)"
    push_gitlab_heads_and_tags "$dir" || {
      error "${repo}: git push to GitLab failed."
      return 1
    }
    return 0
  fi

  gl_refs=$(ls_remote_refs_normalized "$gl_url" || true)

  if [[ "$gh_refs" == "$gl_refs" ]]; then
    log "OK ${repo}: identical to GitLab (ls-remote), no action"
    return 0
  fi

  log "DIFF ${repo}: ref lists differ; syncing via local bare cache"

  dry "mkdir -p ${MIRROR_CACHE}"
  dry "git clone --mirror <github-url> ${dir}   # if missing"
  dry "git -C ${dir} fetch --prune origin"
  dry "git -C ${dir} remote add|set-url gitlab <gitlab-url>"
  dry "git -C ${dir} fetch gitlab +refs/heads/*:refs/remotes/gitlab/*"
  dry "# merge-base per shared branch; then push branches+tags [ --force ] to gitlab"
  [[ "$DRY_RUN" -eq 1 ]] && return 0

  mkdir -p "$MIRROR_CACHE"
  if [[ ! -d "$dir" ]]; then
    git clone --mirror "$gh_url" "$dir" || {
      error "${repo}: git clone --mirror from GitHub failed."
      return 1
    }
  fi
  configure_gitlab_remote "$dir" "$gl_url"
  git -C "$dir" fetch --prune origin || {
    error "${repo}: git fetch --prune origin failed."
    return 1
  }
  git -C "$dir" fetch gitlab "+refs/heads/*:refs/remotes/gitlab/*" 2>/dev/null || true

  local diverged=0
  if branch_divergence_detected "$dir"; then
    diverged=1
  fi

  if [[ "$diverged" -eq 1 ]]; then
    if [[ "$FORCE" -ne 1 ]]; then
      warn "${repo}: diverged on at least one branch; skipping push (re-run with --force to overwrite GitLab)"
      return 0
    fi
    log "PUSH ${repo}: force push branches+tags to gitlab (diverged histories)"
    push_gitlab_heads_and_tags "$dir" --force || {
      error "${repo}: git push --force to GitLab failed."
      return 1
    }
    return 0
  fi

  log "PUSH ${repo}: push branches+tags to gitlab (fast-forwardable / new refs)"
  push_gitlab_heads_and_tags "$dir" || {
    error "${repo}: git push to GitLab failed."
    return 1
  }
}

# --- Namespace resolution (optional) ---
if [[ -n "$EXPLICIT_GITLAB_NAMESPACE_ID" ]]; then
  GITLAB_NAMESPACE_ID="$EXPLICIT_GITLAB_NAMESPACE_ID"
  log "Using explicit GitLab namespace_id=${GITLAB_NAMESPACE_ID}."
elif [[ "$USE_USER_NAMESPACE_LOOKUP" -eq 1 ]]; then
  resolve_gitlab_user_namespace_id || exit 1
fi

mkdir -p "$MIRROR_CACHE"
idx="${MIRROR_CACHE}/.github-repo-index.tsv.tmp.$$"
if ! fetch_github_repo_index >"$idx"; then
  rm -f "$idx"
  error "Failed to list GitHub repositories (check GITHUB_TOKEN and network)."
  exit 1
fi

declare -a REPO_NAMES=()
while IFS=$'\t' read -r name priv; do
  [[ -z "${name:-}" ]] && continue
  REPO_NAMES+=("$name")
  REPO_PRIVATE["$name"]="$priv"
done <"$idx"
rm -f "$idx"

if [[ ${#REPO_NAMES[@]} -eq 0 ]]; then
  log "No repositories returned (affiliation=owner)."
  exit 0
fi

log "Processing ${#REPO_NAMES[@]} GitHub repo(s) (owner, including your forks)."
failures=0
for r in "${REPO_NAMES[@]}"; do
  if ! sync_repo "$r"; then
    failures=$((failures + 1))
    if [[ "$CONTINUE_ON_ERROR" -eq 0 ]]; then
      error "Stopped after first failure (use --continue-on-error to process remaining repos)."
      exit 1
    fi
  fi
done

if [[ "$failures" -gt 0 ]]; then
  error "Finished with ${failures} repo failure(s) out of ${#REPO_NAMES[@]}."
  exit 1
fi

log "Done."
