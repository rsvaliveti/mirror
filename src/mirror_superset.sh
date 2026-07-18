#!/usr/bin/env bash
# Sync GitHub -> GitLab for repos you own (including your forks). No gh/gitlab CLI.
# Tools: bash, git, curl, jq (wget available on Ubuntu but unused here).
#
# Env (required): GITHUB_USER, GITHUB_TOKEN, GITLAB_USER, GITLAB_TOKEN
# Optional: GITHUB_API, GITLAB_HOST (default https://gitlab.com),
#           MIRROR_CACHE (default ~/.cache/mirror-github-to-gitlab),
#           GITLAB_API_RETRIES (default 3), GITLAB_API_RETRY_DELAY seconds (default 2),
#           MIRROR_SYNC_ISSUES=1, MIRROR_SYNC_ISSUE_COMMENTS=1 (same as CLI flags)
#
# Compare GitHub vs GitLab with git ls-remote first (no local clone if identical).
# If refs differ: use persistent bare cache, fetch GitHub + GitLab branch tips, classify
# with merge-base, then push branches+tags to GitLab (not full --mirror: avoids refs/pull/*).
#
# Optional issue migration (--sync-issues): copies GitHub *issues* (not pull requests) into
# GitLab via REST APIs. Labels/milestones/projects are not mapped. State:
# ${MIRROR_CACHE}/.issue-sync/<repo>.json (GitHub number -> GitLab IID).

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: mirror_superset.sh [--dry-run] [--force] [--continue-on-error]
          [--use-user-namespace-id | --gitlab-namespace-id ID]
          [--github-user USER] [--gitlab-user USER] [--sync-issues] [--sync-issue-comments]

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
  --sync-issues             After git mirror steps, copy GitHub issues into GitLab (PRs
                            skipped). Idempotent via ${MIRROR_CACHE}/.issue-sync/<repo>.json.
  --sync-issue-comments     With --sync-issues, copy issue comments as GitLab notes when an
                            issue is first created.

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
SYNC_ISSUES=0
SYNC_ISSUE_COMMENTS=0

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
    --sync-issues) SYNC_ISSUES=1 ;;
    --sync-issue-comments) SYNC_ISSUE_COMMENTS=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
  shift
done

[[ "${MIRROR_SYNC_ISSUES:-0}" == "1" ]] && SYNC_ISSUES=1
[[ "${MIRROR_SYNC_ISSUE_COMMENTS:-0}" == "1" ]] && SYNC_ISSUE_COMMENTS=1
[[ "$SYNC_ISSUE_COMMENTS" -eq 1 ]] && SYNC_ISSUES=1

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
GITLAB_API_RETRIES="${GITLAB_API_RETRIES:-3}"
GITLAB_API_RETRY_DELAY="${GITLAB_API_RETRY_DELAY:-2}"

# Set when --gitlab-namespace-id or successful --use-user-namespace-id lookup.
GITLAB_NAMESPACE_ID=""
# Last HTTP status/body from gitlab_project_get (used by helpers below).
GITLAB_HTTP_CODE=""
GITLAB_LAST_BODY=""

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

gitlab_api_post() {
  curl -sS -f -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" -H "Content-Type: application/json" "$@"
}

gitlab_api_put() {
  curl -sS -f -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" -H "Content-Type: application/json" "$@"
}

gitlab_http_retryable() {
  case "$1" in
    000|429|502|503|504) return 0 ;;
    *) return 1 ;;
  esac
}

# GET /projects/:id. Sets GITLAB_HTTP_CODE and GITLAB_LAST_BODY.
gitlab_project_get() {
  local repo="$1"
  local enc url attempt delay max_retries code body_tmp
  enc=$(gitlab_project_path_encoded "$repo")
  url="${GITLAB_API}/projects/${enc}"
  max_retries="${GITLAB_API_RETRIES}"
  delay="${GITLAB_API_RETRY_DELAY}"
  body_tmp=$(mktemp)

  for attempt in $(seq 1 "$max_retries"); do
    code=$(curl -sS -o "$body_tmp" -w '%{http_code}' -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
      "$url" 2>/dev/null) || code="000"

    if gitlab_http_retryable "$code" && [[ "$attempt" -lt "$max_retries" ]]; then
      warn "GitLab GET ${GITLAB_USER}/${repo}: HTTP ${code}, retry ${attempt}/${max_retries} in ${delay}s"
      sleep "$delay"
      delay=$((delay * 2))
      continue
    fi

    GITLAB_HTTP_CODE="$code"
    GITLAB_LAST_BODY=$(cat "$body_tmp")
    rm -f "$body_tmp"
    return 0
  done

  GITLAB_HTTP_CODE="000"
  GITLAB_LAST_BODY=""
  rm -f "$body_tmp"
  return 0
}

gitlab_get_project_json() {
  local repo="$1"
  gitlab_project_get "$repo"
  [[ "${GITLAB_HTTP_CODE}" == "200" ]] || return 1
  printf '%s' "${GITLAB_LAST_BODY}"
}

gitlab_project_numeric_id() {
  local repo="$1" json
  json=$(gitlab_get_project_json "$repo") || return 1
  printf '%s' "$json" | jq -r '.id | tostring'
}

github_visibility_to_gitlab() {
  [[ "$1" == "true" ]] && printf 'private' || printf 'public'
}

gitlab_api_error_message() {
  local body="$1"
  if [[ -z "$body" ]]; then
    printf '(empty response body)'
    return 0
  fi
  printf '%s' "$body" | jq -r '
    if type == "object" then
      (.message // .error // .)
      | if type == "object" then to_entries | map("\(.key): \(.value)") | join("; ")
        elif type == "array" then join("; ")
        else tostring end
    else tostring end
  ' 2>/dev/null || printf '%s' "$body"
}

gitlab_sync_visibility() {
  local repo="$1"
  local is_private="$2"
  local expected actual json project_id update_body code body_tmp msg
  local attempt delay max_retries
  expected=$(github_visibility_to_gitlab "$is_private")

  json=$(gitlab_get_project_json "$repo") || {
    warn "${repo}: visibility sync skipped (could not read GitLab project)."
    return 0
  }
  actual=$(printf '%s' "$json" | jq -r '.visibility // empty')
  project_id=$(printf '%s' "$json" | jq -r '.id // empty')
  [[ -n "$actual" && -n "$project_id" ]] || return 0
  [[ "$actual" == "$expected" ]] && return 0

  log "VISIBILITY ${repo}: GitLab=${actual} GitHub=${expected}; updating GitLab"
  update_body=$(jq -n --arg v "$expected" '{visibility: $v}')
  dry "PUT ${GITLAB_API}/projects/${project_id} visibility=${expected}"
  [[ "$DRY_RUN" -eq 1 ]] && return 0

  body_tmp=$(mktemp)
  max_retries="${GITLAB_API_RETRIES}"
  delay="${GITLAB_API_RETRY_DELAY}"
  for attempt in $(seq 1 "$max_retries"); do
    code=$(curl -sS -o "$body_tmp" -w '%{http_code}' \
      -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" -H "Content-Type: application/json" \
      -X PUT "${GITLAB_API}/projects/${project_id}" -d "$update_body" 2>/dev/null) || code="000"

    if [[ "$code" == "200" ]]; then
      rm -f "$body_tmp"
      return 0
    fi
    if gitlab_http_retryable "$code" && [[ "$attempt" -lt "$max_retries" ]]; then
      warn "GitLab PUT visibility ${repo}: HTTP ${code}, retry ${attempt}/${max_retries} in ${delay}s"
      sleep "$delay"
      delay=$((delay * 2))
      continue
    fi
    msg=$(gitlab_api_error_message "$(cat "$body_tmp" 2>/dev/null)")
    warn "${repo}: visibility update failed (HTTP ${code}): ${msg}"
    rm -f "$body_tmp"
    return 0
  done
  rm -f "$body_tmp"
  return 0
}

# Copy GitHub issues (not PRs) into GitLab. Idempotent via state JSON mapping
# GitHub issue number (string key) -> GitLab IID (string value).
sync_github_issues_to_gitlab() {
  local repo="$1"
  local state_dir="${MIRROR_CACHE}/.issue-sync"
  local state_file="${state_dir}/${repo}.json"
  local map='{}'
  local project_id page iss count num mapped title gh_state body_html html_url create_resp
  local gl_json gl_iid issue_json cpage cjson author cbody note_payload cc crow
  local iss_scanned=0 iss_skip_mapped=0 iss_created=0 iss_dry_plan=0 iss_failed=0 comments_ok=0 prs_skipped=0

  mkdir -p "$state_dir"
  [[ -f "$state_file" ]] && map=$(cat "$state_file")

  project_id=$(gitlab_project_numeric_id "$repo") || {
    warn "${repo}: issue sync skipped (could not resolve GitLab project id)."
    return 0
  }

  page=1
  while true; do
    iss=$(gh_curl "${GITHUB_API}/repos/${GITHUB_USER}/${repo}/issues?state=all&sort=created&direction=asc&per_page=100&page=${page}") || {
      warn "${repo}: issue sync stopped (GitHub issues API error on page ${page})."
      log "ISSUES ${repo} summary (partial): scanned=${iss_scanned}, already mapped=${iss_skip_mapped}, created=${iss_created}, dry-run would create=${iss_dry_plan}, failed=${iss_failed}, comments copied=${comments_ok}, GitHub PRs skipped=${prs_skipped}"
      return 0
    }
    if ! printf '%s' "$iss" | jq -e 'type == "array"' &>/dev/null; then
      warn "${repo}: issue sync skipped (GitHub returned non-array; check token scopes for issues read)."
      return 0
    fi
    count=$(printf '%s' "$iss" | jq 'length')
    [[ "$count" -eq 0 ]] && break

    prs_skipped=$((prs_skipped + $(printf '%s' "$iss" | jq '[.[] | select(.pull_request != null)] | length')))

    while IFS= read -r issue_json; do
      [[ -z "$issue_json" ]] && continue
      iss_scanned=$((iss_scanned + 1))
      num=$(printf '%s' "$issue_json" | jq -r '.number')
      mapped=$(printf '%s' "$map" | jq -r --arg n "$num" '.[$n] // empty')
      if [[ -n "$mapped" ]]; then
        iss_skip_mapped=$((iss_skip_mapped + 1))
        continue
      fi

      title=$(printf '%s' "$issue_json" | jq -r '.title // "Untitled"')
      gh_state=$(printf '%s' "$issue_json" | jq -r '.state // "open"')
      body_html=$(printf '%s' "$issue_json" | jq -r '.body // ""')
      html_url=$(printf '%s' "$issue_json" | jq -r '.html_url // ""')
      create_resp=$(jq -n \
        --arg t "$title" \
        --arg n "$num" \
        --arg u "$html_url" \
        --arg b "$body_html" \
        '{title: $t, description: ("<!-- mirror-github-issue:" + $n + " -->\n\n[Migrated from GitHub](" + $u + ").\n\n---\n\n" + $b)}')

      dry "POST ${GITLAB_API}/projects/${project_id}/issues (GitHub#${num}): ${title}"
      if [[ "$DRY_RUN" -eq 1 ]]; then
        iss_dry_plan=$((iss_dry_plan + 1))
        continue
      fi

      gl_json=$(gitlab_api_post -X POST "${GITLAB_API}/projects/${project_id}/issues" -d "$create_resp") || {
        warn "${repo}: failed to create GitLab issue for GitHub#${num}."
        iss_failed=$((iss_failed + 1))
        continue
      }
      gl_iid=$(printf '%s' "$gl_json" | jq -r '.iid // empty')
      if [[ -z "$gl_iid" ]]; then
        iss_failed=$((iss_failed + 1))
        continue
      fi

      iss_created=$((iss_created + 1))
      map=$(printf '%s' "$map" | jq --arg k "$num" --arg v "$gl_iid" '. + {($k): $v}')
      printf '%s\n' "$map" >"${state_file}.tmp.$$" && mv -f "${state_file}.tmp.$$" "$state_file"

      if [[ "$gh_state" == "closed" ]]; then
        gitlab_api_put -X PUT "${GITLAB_API}/projects/${project_id}/issues/${gl_iid}" \
          -d '{"state_event":"close"}' >/dev/null 2>&1 || warn "${repo}: could not close GitLab IID ${gl_iid} (GitHub#${num})."
      fi

      if [[ "$SYNC_ISSUE_COMMENTS" -eq 1 ]]; then
        cpage=1
        while true; do
          cjson=$(gh_curl "${GITHUB_API}/repos/${GITHUB_USER}/${repo}/issues/${num}/comments?per_page=100&page=${cpage}") || break
          cc=$(printf '%s' "$cjson" | jq 'length')
          [[ "$cc" -eq 0 ]] && break
          while IFS= read -r crow; do
            [[ -z "$crow" ]] && continue
            author=$(printf '%s' "$crow" | jq -r '.user.login // "unknown"')
            cbody=$(printf '%s' "$crow" | jq -r '.body // ""')
            note_payload=$(jq -n --arg u "$author" --arg b "$cbody" '{body: ("**@" + $u + "** (GitHub):\n\n" + $b)}')
            if gitlab_api_post -X POST "${GITLAB_API}/projects/${project_id}/issues/${gl_iid}/notes" \
              -d "$note_payload" >/dev/null 2>&1; then
              comments_ok=$((comments_ok + 1))
            fi
          done < <(printf '%s' "$cjson" | jq -c '.[]')
          [[ "$cc" -lt 100 ]] && break
          cpage=$((cpage + 1))
        done
      fi
    done < <(printf '%s' "$iss" | jq -c '.[] | select(.pull_request == null)')

    [[ "$count" -lt 100 ]] && break
    page=$((page + 1))
  done

  local comment_note=""
  [[ "$SYNC_ISSUE_COMMENTS" -ne 1 ]] && comment_note=" (comment sync disabled)"

  local dry_note=""
  [[ "$iss_dry_plan" -gt 0 ]] && dry_note=" dry-run would create=${iss_dry_plan};"

  if [[ "$iss_scanned" -eq 0 && "$prs_skipped" -eq 0 ]]; then
    log "ISSUES ${repo} summary: no GitHub issues returned (empty list or no access)."
  elif [[ "$iss_scanned" -eq 0 && "$prs_skipped" -gt 0 ]]; then
    log "ISSUES ${repo} summary: no standalone GitHub issues on scanned pages (${prs_skipped} pull request(s) skipped; PRs are not migrated)."
  else
    log "ISSUES ${repo} summary: scanned=${iss_scanned} GitHub issue(s) (non-PR); already on GitLab=${iss_skip_mapped}; new issue(s) created=${iss_created}; comment(s) copied=${comments_ok}${comment_note};${dry_note} create failure(s)=${iss_failed}; pull request(s) skipped=${prs_skipped}."
  fi
  return 0
}

maybe_sync_github_issues() {
  local repo="$1"
  local gl_code="$2"
  [[ "$SYNC_ISSUES" -eq 1 ]] || return 0
  [[ "$gl_code" == "200" ]] || return 0
  sync_github_issues_to_gitlab "$repo" || true
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
  gitlab_project_get "$1"
  printf '%s' "${GITLAB_HTTP_CODE}"
}

gitlab_create_project() {
  local repo="$1"
  local is_private="$2"
  local visibility="public"
  [[ "$is_private" == "true" ]] && visibility="private"
  local body code body_tmp msg attempt delay max_retries
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

  body_tmp=$(mktemp)
  max_retries="${GITLAB_API_RETRIES}"
  delay="${GITLAB_API_RETRY_DELAY}"
  for attempt in $(seq 1 "$max_retries"); do
    code=$(curl -sS -o "$body_tmp" -w '%{http_code}' \
      -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" -H "Content-Type: application/json" \
      -X POST "${GITLAB_API}/projects" -d "$body" 2>/dev/null) || code="000"

    if [[ "$code" == "201" ]]; then
      rm -f "$body_tmp"
      return 0
    fi

    if [[ "$code" == "400" ]]; then
      gitlab_project_get "$repo"
      if [[ "${GITLAB_HTTP_CODE}" == "200" ]]; then
        warn "${repo}: create returned HTTP 400 but project already exists; continuing."
        rm -f "$body_tmp"
        return 0
      fi
    fi

    if gitlab_http_retryable "$code" && [[ "$attempt" -lt "$max_retries" ]]; then
      warn "GitLab POST create ${repo}: HTTP ${code}, retry ${attempt}/${max_retries} in ${delay}s"
      sleep "$delay"
      delay=$((delay * 2))
      continue
    fi

    msg=$(gitlab_api_error_message "$(cat "$body_tmp" 2>/dev/null)")
    error "GitLab API: failed to create project '${repo}' (${GITLAB_USER}/${repo}, HTTP ${code}): ${msg}"
    rm -f "$body_tmp"
    return 1
  done

  error "GitLab API: failed to create project '${repo}' (${GITLAB_USER}/${repo}, HTTP 000): exhausted retries"
  rm -f "$body_tmp"
  return 1
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
  gl_code=$(gitlab_project_http_code "$repo")

  gh_refs=$(ls_remote_refs_normalized "$gh_url" || true)
  if [[ -z "$gh_refs" ]]; then
    warn "${repo}: no refs from GitHub (empty or unreachable), skip"
    maybe_sync_github_issues "$repo" "$gl_code"
    return 0
  fi

  if [[ "$gl_code" == "000" ]] || gitlab_http_retryable "$gl_code"; then
    error "${repo}: could not reach GitLab API or project URL (HTTP ${gl_code})."
    return 1
  fi

  if [[ "$gl_code" == "200" ]]; then
    gitlab_sync_visibility "$repo" "$is_private"
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
    gitlab_sync_visibility "$repo" "$is_private"
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
    maybe_sync_github_issues "$repo" 200
    return 0
  fi

  gl_refs=$(ls_remote_refs_normalized "$gl_url" || true)

  if [[ "$gh_refs" == "$gl_refs" ]]; then
    log "OK ${repo}: identical to GitLab (ls-remote), no action"
    maybe_sync_github_issues "$repo" "$gl_code"
    return 0
  fi

  log "DIFF ${repo}: ref lists differ; syncing via local bare cache"

  dry "mkdir -p ${MIRROR_CACHE}"
  dry "git clone --mirror <github-url> ${dir}   # if missing"
  dry "git -C ${dir} fetch --prune origin"
  dry "git -C ${dir} remote add|set-url gitlab <gitlab-url>"
  dry "git -C ${dir} fetch gitlab +refs/heads/*:refs/remotes/gitlab/*"
  dry "# merge-base per shared branch; then push branches+tags [ --force ] to gitlab"
  [[ "$DRY_RUN" -eq 1 ]] && {
    maybe_sync_github_issues "$repo" "$gl_code"
    return 0
  }

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
      maybe_sync_github_issues "$repo" "$gl_code"
      return 0
    fi
    log "PUSH ${repo}: force push branches+tags to gitlab (diverged histories)"
    push_gitlab_heads_and_tags "$dir" --force || {
      error "${repo}: git push --force to GitLab failed."
      return 1
    }
    maybe_sync_github_issues "$repo" "$gl_code"
    return 0
  fi

  log "PUSH ${repo}: push branches+tags to gitlab (fast-forwardable / new refs)"
  push_gitlab_heads_and_tags "$dir" || {
    error "${repo}: git push to GitLab failed."
    return 1
  }
  maybe_sync_github_issues "$repo" "$gl_code"
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
