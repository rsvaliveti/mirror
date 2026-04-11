#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [--force] [--dry-run] [--github-user USER] [--gitlab-user USER]

Mirrors all GitHub repos of GITHUB_USER to GitLab as GITLAB_USER.

Env vars (required unless overridden by flags):
  GITHUB_USER, GITHUB_TOKEN
  GITLAB_USER, GITLAB_TOKEN

Options:
  --force       Force-push to GitLab when histories diverge
  --dry-run     Show what would be executed, no network-changing git or API calls
  --github-user Override GITHUB_USER
  --gitlab-user Override GITLAB_USER
EOF
}

FORCE=0
DRY_RUN=0
OVERRIDE_GITHUB_USER=""
OVERRIDE_GITLAB_USER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --github-user) OVERRIDE_GITHUB_USER="$2"; shift 2 ;;
    --gitlab-user) OVERRIDE_GITLAB_USER="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"
: "${GITLAB_TOKEN:?GITLAB_TOKEN is required}"
GITHUB_USER="${OVERRIDE_GITHUB_USER:-${GITHUB_USER:?GITHUB_USER is required}}"
GITLAB_USER="${OVERRIDE_GITLAB_USER:-${GITLAB_USER:?GITLAB_USER is required}}"

GITHUB_API="https://api.github.com"
GITLAB_API="https://gitlab.com/api/v4"

info()  { printf '[INFO] %s\n' "$*"; }
warn()  { printf '[WARN] %s\n' "$*" >&2; }
error() { printf '[ERROR] %s\n' "$*" >&2; }

api_get_github() {
  local url="$1"
  curl -sSf -u "${GITHUB_USER}:${GITHUB_TOKEN}" "$url"
}

api_get_gitlab() {
  local url="$1"
  curl -sSf --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" "$url"
}

api_post_gitlab() {
  local url="$1"; shift
  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "DRY-RUN: POST $url $*"
    return 0
  fi
  curl -sSf --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" -X POST "$url" "$@"
}

git_ls_remote() {
  local url="$1" ref="$2"
  git ls-remote --heads "$url" "$ref" 2>/dev/null | awk '{print $1}' | head -n1
}

get_github_repos() {
  local page=1 per_page=100
  while :; do
    local url="${GITHUB_API}/user/repos?per_page=${per_page}&page=${page}&affiliation=owner"
    local json
    json="$(api_get_github "$url")" || break
    local count
    count="$(printf '%s\n' "$json" | jq 'length')"
    if [[ "$count" -eq 0 ]]; then
      break
    fi
    printf '%s\n' "$json"
    if [[ "$count" -lt $per_page ]]; then
      break
    fi
    page=$((page+1))
  done
}

get_gitlab_user_id() {
  if [[ -n "${_GITLAB_USER_ID:-}" ]]; then
    printf '%s\n' "$_GITLAB_USER_ID"
    return
  fi
  local encoded_user
  encoded_user="$(printf '%s' "$GITLAB_USER" | jq -sRr @uri)"
  local json
  json="$(api_get_gitlab "${GITLAB_API}/users?username=${encoded_user}")"
  local id
  id="$(printf '%s\n' "$json" | jq '.[0].id // empty')"
  if [[ -z "$id" ]]; then
    error "GitLab user ${GITLAB_USER} not found"
    exit 1
  fi
  _GITLAB_USER_ID="$id"
  printf '%s\n' "$id"
}

get_gitlab_project() {
  local path="$1"
  local encoded
  encoded="$(printf '%s' "$path" | jq -sRr @uri)"
  api_get_gitlab "${GITLAB_API}/projects/${encoded}" 2>/dev/null || true
}

ensure_gitlab_project() {
  local name="$1"
  local path="$2"

  local existing
  existing="$(get_gitlab_project "${GITLAB_USER}/${path}")"
  if [[ -n "$existing" && "$(printf '%s\n' "$existing" | jq '.id // empty')" != "" ]]; then
    printf '%s\n' "$existing"
    return
  fi

  local user_id
  user_id="$(get_gitlab_user_id)"
  info "Creating GitLab project ${GITLAB_USER}/${path}"
  local json
  json="$(api_post_gitlab "${GITLAB_API}/projects" \
          --data-urlencode "name=${name}" \
          --data-urlencode "path=${path}" \
          --data-urlencode "namespace_id=${user_id}")"
  printf '%s\n' "$json"
}

mirror_repo() {
  local gh_name="$1"
  local gh_default_branch="$2"

  info "Processing repo: ${gh_name} (default: ${gh_default_branch})"

  local gl_path="$gh_name"
  local gl_project_json
  gl_project_json="$(ensure_gitlab_project "$gh_name" "$gl_path")"
  local gl_http_url
  gl_http_url="$(printf '%s\n' "$gl_project_json" | jq -r '.http_url_to_repo')"

  local gh_url="https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com/${GITHUB_USER}/${gh_name}.git"
  local gl_url="https://oauth2:${GITLAB_TOKEN}@gitlab.com/${GITLAB_USER}/${gh_name}.git"

  local gh_ref="refs/heads/${gh_default_branch}"
  local gl_ref="$gh_ref"

  local gh_head gl_head
  gh_head="$(git_ls_remote "$gh_url" "$gh_ref" || true)"
  gl_head="$(git_ls_remote "$gl_url" "$gl_ref" || true)"

  if [[ -z "$gh_head" ]]; then
    warn "GitHub repo ${gh_name} missing default branch ${gh_default_branch}, skipping"
    return
  fi

  if [[ -z "$gl_head" ]]; then
    info "GitLab repo ${gh_name} missing branch, will full mirror"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      info "DRY-RUN: git clone --mirror \"$gh_url\" && git push --mirror \"$gl_url\""
      return
    fi
    local tmpdir
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN
    (cd "$tmpdir" && 
     git clone --mirror "$gh_url" repo &&
     cd repo &&
     git remote set-url --push origin "$gl_url" &&
     git push --mirror "$gl_url")
    return
  fi

  if [[ "$gh_head" == "$gl_head" ]]; then
    info "Repos in sync on ${gh_default_branch} for ${gh_name}"
    return
  fi

  info "Repos differ for ${gh_name}, deeper analysis needed"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    action="git push --mirror"
    [[ "$FORCE" -eq 1 ]] && action="git push --mirror --force"
    info "DRY-RUN: $action \"$gl_url\""
    return
  fi

  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN
  (cd "$tmpdir" &&
   git clone --mirror "$gh_url" repo &&
   cd repo &&
   git remote add gitlab "$gl_url" &&
   git fetch gitlab --prune &&
   local head_gh head_gl base
   head_gh="$(git rev-parse --verify HEAD)" &&
   head_gl="$(git rev-parse --verify refs/remotes/gitlab/${gh_default_branch} 2>/dev/null || true)" &&
   if [[ -z "$head_gl" ]]; then
     info "GitLab missing branch, full mirror"
     git push --mirror "$gl_url"
   elif [[ "$head_gh" == "$head_gl" ]]; then
     info "Heads match after fetch"
   else
     base="$(git merge-base "$head_gh" "$head_gl" 2>/dev/null || true)"
     if [[ "$base" == "$head_gl" ]]; then
       info "GitLab behind, fast-forward"
       git push "$gl_url" HEAD:${gh_default_branch}
     elif [[ "$FORCE" -eq 1 ]]; then
       warn "Diverged, force pushing GitHub to GitLab"
       git push --mirror --force "$gl_url"
     else
       warn "Diverged and --force not set, skipping ${gh_name}"
     fi
   fi)
}

main() {
  local repos_json
  repos_json="$(get_github_repos)"
  
  printf '%s\n' "$repos_json" | jq -r '.[] | select(.fork == false and .archived == false) | [.name, .default_branch] | @tsv' | \
  while IFS=$'\t' read -r name default_branch; do
    mirror_repo "$name" "$default_branch"
  done
}

main "$@"
