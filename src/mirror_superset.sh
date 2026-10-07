#!/usr/bin/env bash
# Sync GitHub -> GitLab (default) or GitHub <-> GitLab (--bidirectional) for repos you
# own (including your forks). No gh/gitlab CLI.
# Tools: bash, git, curl, jq (wget available on Ubuntu but unused here).
#
# Env (required): GITHUB_USER, GITHUB_TOKEN, GITLAB_USER, GITLAB_TOKEN
# Optional: GITHUB_API, GITLAB_HOST (default https://gitlab.com),
#           MIRROR_CACHE (default ~/.cache/mirror-github-to-gitlab),
#           GITLAB_API_RETRIES (default 3), GITLAB_API_RETRY_DELAY seconds (default 2),
#           MIRROR_SYNC_ISSUES=1, MIRROR_SYNC_ISSUE_COMMENTS=1 (same as CLI flags),
#           MIRROR_BIDIRECTIONAL=1 (same as --bidirectional)
#
# Compare GitHub vs GitLab with git ls-remote first (no local clone if identical).
# One-way: if refs differ, use persistent bare cache, fetch GitHub + GitLab branch tips,
# classify with merge-base, then push branches+tags to GitLab (not full --mirror: avoids
# refs/pull/*). Bidirectional: union inventory, create missing repos either way, per-ref
# fast-forward both directions, never prune; skip diverged branches and tag SHA clashes.
#
# Optional issue migration (--sync-issues): copies GitHub *issues* (not pull requests) into
# GitLab via REST APIs (still one-way). Labels/milestones/projects are not mapped. State:
# ${MIRROR_CACHE}/.issue-sync/<repo>.json (GitHub number -> GitLab IID).

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: mirror_superset.sh [--dry-run] [--force] [--bidirectional] [--continue-on-error]
          [--use-user-namespace-id | --gitlab-namespace-id ID]
          [--github-user USER] [--gitlab-user USER] [--sync-issues] [--sync-issue-comments]

  --dry-run                 Log operations; no POST /projects, no git fetch/push.
  --force                   If any shared branch diverged, force-push branches+tags to GitLab.
                            Incompatible with --bidirectional.
  --bidirectional           Two-way fast-forward: union GitHub+GitLab inventory, create
                            missing repos either way, per-ref FF both directions, never prune.
                            Diverged branches and tag SHA clashes are skipped.
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

Default: GitHub → GitLab. Lists GitHub repos with affiliation=owner (your repos and forks).
When a one-way push runs, syncs all branches and tags (not git push --mirror, to avoid GitHub PR refs).
--bidirectional also lists owned GitLab projects and fast-forwards refs either way.

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
BIDIRECTIONAL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --force) FORCE=1 ;;
    --bidirectional) BIDIRECTIONAL=1 ;;
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
[[ "${MIRROR_BIDIRECTIONAL:-0}" == "1" ]] && BIDIRECTIONAL=1
[[ "$SYNC_ISSUE_COMMENTS" -eq 1 ]] && SYNC_ISSUES=1

if [[ "$BIDIRECTIONAL" -eq 1 && "$FORCE" -eq 1 ]]; then
  printf '[ERROR] %s\n' "--force cannot be combined with --bidirectional (diverged refs are skipped)." >&2
  exit 1
fi

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
GITHUB_HTTP_CODE=""
GITHUB_LAST_BODY=""

declare -A REPO_PRIVATE=()
declare -A REPO_ON_GITHUB=()
declare -A REPO_ON_GITLAB=()
declare -A REPO_GL_VISIBILITY=()

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

# --- Bidirectional v1: per-ref fast-forward, never prune, skip conflicts ---

github_http_retryable() {
  gitlab_http_retryable "$1"
}

# GET/POST/PATCH GitHub. Sets GITHUB_HTTP_CODE and GITHUB_LAST_BODY.
github_api_request() {
  local method="$1" url="$2" body="${3:-}"
  local attempt delay max_retries code body_tmp
  max_retries="${GITLAB_API_RETRIES}"
  delay="${GITLAB_API_RETRY_DELAY}"
  body_tmp=$(mktemp)

  for attempt in $(seq 1 "$max_retries"); do
    if [[ -n "$body" ]]; then
      code=$(curl -sS -o "$body_tmp" -w '%{http_code}' -X "$method" \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -H "Content-Type: application/json" \
        -d "$body" "$url" 2>/dev/null) || code="000"
    else
      code=$(curl -sS -o "$body_tmp" -w '%{http_code}' -X "$method" \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "$url" 2>/dev/null) || code="000"
    fi

    if github_http_retryable "$code" && [[ "$attempt" -lt "$max_retries" ]]; then
      warn "GitHub ${method} ${url}: HTTP ${code}, retry ${attempt}/${max_retries} in ${delay}s"
      sleep "$delay"
      delay=$((delay * 2))
      continue
    fi

    GITHUB_HTTP_CODE="$code"
    GITHUB_LAST_BODY=$(cat "$body_tmp")
    rm -f "$body_tmp"
    return 0
  done

  GITHUB_HTTP_CODE="000"
  GITHUB_LAST_BODY=""
  rm -f "$body_tmp"
  return 0
}

# GET arbitrary GitLab URL. Sets GITLAB_HTTP_CODE and GITLAB_LAST_BODY.
gitlab_http_get() {
  local url="$1"
  local attempt delay max_retries code body_tmp
  max_retries="${GITLAB_API_RETRIES}"
  delay="${GITLAB_API_RETRY_DELAY}"
  body_tmp=$(mktemp)

  for attempt in $(seq 1 "$max_retries"); do
    code=$(curl -sS -o "$body_tmp" -w '%{http_code}' -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
      "$url" 2>/dev/null) || code="000"

    if gitlab_http_retryable "$code" && [[ "$attempt" -lt "$max_retries" ]]; then
      warn "GitLab GET ${url}: HTTP ${code}, retry ${attempt}/${max_retries} in ${delay}s"
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

gitlab_visibility_to_github_private() {
  case "$1" in
    public) printf 'false' ;;
    *) printf 'true' ;;
  esac
}

join_csv() {
  local out="" n
  while IFS= read -r n; do
    [[ -z "$n" ]] && continue
    if [[ -z "$out" ]]; then
      out="$n"
    else
      out="${out}, ${n}"
    fi
  done
  [[ -z "$out" ]] && out="(none)"
  printf '%s' "$out"
}

parse_ls_remote_heads_tags() {
  local refs="$1"
  local heads_file="$2"
  local tags_file="$3"
  : >"$heads_file"
  : >"$tags_file"
  [[ -z "$refs" ]] && return 0
  while IFS=$'\t' read -r sha ref; do
    [[ -z "${ref:-}" ]] && continue
    case "$ref" in
      refs/heads/*) printf '%s\t%s\n' "${ref#refs/heads/}" "$sha" >>"$heads_file" ;;
      refs/tags/*) printf '%s\t%s\n' "${ref#refs/tags/}" "$sha" >>"$tags_file" ;;
    esac
  done <<< "$refs"
}

write_cache_refs() {
  local dir="$1" prefix="$2" file="$3"
  git -C "$dir" for-each-ref --format='%(refname)%09%(objectname)' "$prefix" \
    | awk -F '\t' -v p="$prefix" '{
        name=$1
        sub("^" p, "", name)
        if (name != "") print name "\t" $2
      }' >"$file"
}

ref_sha_from_file() {
  local file="$1" name="$2"
  awk -F '\t' -v n="$name" '$1 == n { print $2; exit }' "$file"
}

unique_ref_names() {
  local f1="$1" f2="$2"
  awk -F '\t' 'NF { print $1 }' "$f1" "$f2" | LC_ALL=C sort -u
}

ensure_git_remote() {
  local dir="$1" name="$2" url="$3"
  dry "git -C ${dir} remote add|set-url ${name} <url>"
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  if git -C "$dir" remote get-url "$name" &>/dev/null; then
    git -C "$dir" remote set-url "$name" "$url"
  else
    git -C "$dir" remote add "$name" "$url"
  fi
}

ensure_bare_cache() {
  local dir="$1"
  mkdir -p "$MIRROR_CACHE"
  if [[ ! -d "$dir" ]]; then
    dry "git init --bare ${dir}"
    [[ "$DRY_RUN" -eq 1 ]] && return 0
    git init --bare "$dir" || return 1
  fi
  return 0
}

# Fetch heads+tags into namespaced refs (never refs/pull/* or refs/merge-requests/*).
fetch_bidirectional_refs() {
  local dir="$1"
  dry "git -C ${dir} fetch --prune github +refs/heads/*:refs/remotes/github/* +refs/tags/*:refs/sync/github/tags/*"
  dry "git -C ${dir} fetch --prune gitlab +refs/heads/*:refs/remotes/gitlab/* +refs/tags/*:refs/sync/gitlab/tags/*"
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  git -C "$dir" fetch --prune github \
    "+refs/heads/*:refs/remotes/github/*" \
    "+refs/tags/*:refs/sync/github/tags/*" || return 1
  git -C "$dir" fetch --prune gitlab \
    "+refs/heads/*:refs/remotes/gitlab/*" \
    "+refs/tags/*:refs/sync/gitlab/tags/*" || return 1
}

push_named_ref() {
  local dir="$1" remote="$2" src="$3" dst="$4"
  dry "git -C ${dir} push ${remote} ${src}:${dst}"
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  git -C "$dir" push "$remote" "${src}:${dst}"
}

github_create_repo() {
  local repo="$1"
  local is_private="$2"
  local private_json="false"
  local body
  [[ "$is_private" == "true" ]] && private_json="true"
  body=$(jq -n --arg name "$repo" --argjson private "$private_json" \
    '{name: $name, private: $private, auto_init: false}')
  dry "POST ${GITHUB_API}/user/repos name=${repo} private=${private_json}"
  [[ "$DRY_RUN" -eq 1 ]] && return 0

  github_api_request POST "${GITHUB_API}/user/repos" "$body"
  if [[ "${GITHUB_HTTP_CODE}" == "201" ]]; then
    return 0
  fi
  if [[ "${GITHUB_HTTP_CODE}" == "422" ]]; then
    github_api_request GET "${GITHUB_API}/repos/${GITHUB_USER}/${repo}"
    if [[ "${GITHUB_HTTP_CODE}" == "200" ]]; then
      warn "${repo}: GitHub create returned HTTP 422 but repository already exists; continuing."
      return 0
    fi
  fi
  error "GitHub API: failed to create repository '${repo}' (HTTP ${GITHUB_HTTP_CODE}): $(gitlab_api_error_message "${GITHUB_LAST_BODY}")"
  return 1
}

github_set_default_branch() {
  local repo="$1" branch="$2"
  local body
  [[ -z "$branch" ]] && return 0
  body=$(jq -n --arg b "$branch" '{default_branch: $b}')
  dry "PATCH ${GITHUB_API}/repos/${GITHUB_USER}/${repo} default_branch=${branch}"
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  github_api_request PATCH "${GITHUB_API}/repos/${GITHUB_USER}/${repo}" "$body"
  if [[ "${GITHUB_HTTP_CODE}" != "200" ]]; then
    warn "${repo}: could not set GitHub default_branch=${branch} (HTTP ${GITHUB_HTTP_CODE})."
  fi
  return 0
}

gitlab_set_default_branch() {
  local repo="$1" branch="$2"
  local project_id body
  [[ -z "$branch" ]] && return 0
  project_id=$(gitlab_project_numeric_id "$repo") || {
    warn "${repo}: could not set GitLab default_branch=${branch} (no project id)."
    return 0
  }
  body=$(jq -n --arg b "$branch" '{default_branch: $b}')
  dry "PUT ${GITLAB_API}/projects/${project_id} default_branch=${branch}"
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  gitlab_api_put -X PUT "${GITLAB_API}/projects/${project_id}" -d "$body" >/dev/null 2>&1 \
    || warn "${repo}: could not set GitLab default_branch=${branch}."
  return 0
}

fetch_gitlab_project_index() {
  local page=1
  local base json count
  local filter_personal=0

  if [[ -n "${GITLAB_NAMESPACE_ID}" ]]; then
    gitlab_http_get "${GITLAB_API}/groups/${GITLAB_NAMESPACE_ID}"
    if [[ "${GITLAB_HTTP_CODE}" == "200" ]]; then
      base="${GITLAB_API}/groups/${GITLAB_NAMESPACE_ID}/projects?simple=true&archived=false&per_page=100"
    else
      base="${GITLAB_API}/users/${GITLAB_NAMESPACE_ID}/projects?simple=true&archived=false&per_page=100"
    fi
  else
    base="${GITLAB_API}/projects?owned=true&simple=true&archived=false&per_page=100"
    filter_personal=1
  fi

  while true; do
    gitlab_http_get "${base}&page=${page}"
    if [[ "${GITLAB_HTTP_CODE}" != "200" ]]; then
      error "Failed to list GitLab projects (HTTP ${GITLAB_HTTP_CODE}): $(gitlab_api_error_message "${GITLAB_LAST_BODY}")"
      return 1
    fi
    json="${GITLAB_LAST_BODY}"
    if ! printf '%s' "$json" | jq -e 'type == "array"' &>/dev/null; then
      error "GitLab project list returned non-array (HTTP ${GITLAB_HTTP_CODE})."
      return 1
    fi
    count=$(printf '%s' "$json" | jq 'length')
    [[ "$count" -eq 0 ]] && break
    if [[ "$filter_personal" -eq 1 ]]; then
      printf '%s' "$json" | jq -r --arg ns "$GITLAB_USER" \
        '.[] | select(.namespace.path == $ns) | [.path, (.visibility // "private")] | @tsv'
    else
      printf '%s' "$json" | jq -r '.[] | [.path, (.visibility // "private")] | @tsv'
    fi
    [[ "$count" -lt 100 ]] && break
    page=$((page + 1))
  done
}

# Classify heads from two name/sha TSV files.
# with_objects=1 uses merge-base in $dir; 0 treats unequal SHAs as needs-fetch.
# Appends names to the given files (gh2gl, gl2gh, diverged, needs_fetch).
classify_heads() {
  local dir="$1" gh_file="$2" gl_file="$3" with_objects="$4"
  local gh2gl="$5" gl2gh="$6" diverged="$7" needs_fetch="$8"
  local bn gh_sha gl_sha

  while IFS= read -r bn; do
    [[ -z "$bn" ]] && continue
    gh_sha=$(ref_sha_from_file "$gh_file" "$bn")
    gl_sha=$(ref_sha_from_file "$gl_file" "$bn")
    if [[ -z "$gh_sha" && -n "$gl_sha" ]]; then
      printf '%s\n' "$bn" >>"$gl2gh"
      continue
    fi
    if [[ -n "$gh_sha" && -z "$gl_sha" ]]; then
      printf '%s\n' "$bn" >>"$gh2gl"
      continue
    fi
    [[ "$gh_sha" == "$gl_sha" ]] && continue
    if [[ "$with_objects" -eq 0 ]]; then
      printf '%s\n' "$bn" >>"$needs_fetch"
      continue
    fi
    gh_sha=$(git -C "$dir" rev-parse "refs/remotes/github/${bn}^{commit}" 2>/dev/null) || gh_sha=""
    gl_sha=$(git -C "$dir" rev-parse "refs/remotes/gitlab/${bn}^{commit}" 2>/dev/null) || gl_sha=""
    if [[ -z "$gh_sha" || -z "$gl_sha" ]]; then
      printf '%s\n' "$bn" >>"$needs_fetch"
      continue
    fi
    if git -C "$dir" merge-base --is-ancestor "$gl_sha" "$gh_sha" 2>/dev/null; then
      printf '%s\n' "$bn" >>"$gh2gl"
    elif git -C "$dir" merge-base --is-ancestor "$gh_sha" "$gl_sha" 2>/dev/null; then
      printf '%s\n' "$bn" >>"$gl2gh"
    else
      printf '%s\n' "$bn" >>"$diverged"
    fi
  done < <(unique_ref_names "$gh_file" "$gl_file")
}

classify_tags() {
  local gh_file="$1" gl_file="$2"
  local gh2gl="$3" gl2gh="$4" clash="$5"
  local tag gh_sha gl_sha

  while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue
    gh_sha=$(ref_sha_from_file "$gh_file" "$tag")
    gl_sha=$(ref_sha_from_file "$gl_file" "$tag")
    if [[ -z "$gh_sha" && -n "$gl_sha" ]]; then
      printf '%s\n' "$tag" >>"$gl2gh"
    elif [[ -n "$gh_sha" && -z "$gl_sha" ]]; then
      printf '%s\n' "$tag" >>"$gh2gl"
    elif [[ "$gh_sha" != "$gl_sha" ]]; then
      printf '%s\n' "$tag" >>"$clash"
    fi
  done < <(unique_ref_names "$gh_file" "$gl_file")
}

log_bidirectional_plan() {
  local repo="$1" work="$2"
  log "PLAN ${repo} heads GH→GL: $(join_csv <"${work}/h_gh2gl")"
  log "PLAN ${repo} heads GL→GH: $(join_csv <"${work}/h_gl2gh")"
  log "PLAN ${repo} heads skip diverged: $(join_csv <"${work}/h_diverged")"
  log "PLAN ${repo} heads classify after fetch: $(join_csv <"${work}/h_fetch")"
  log "PLAN ${repo} tags GH→GL: $(join_csv <"${work}/t_gh2gl")"
  log "PLAN ${repo} tags GL→GH: $(join_csv <"${work}/t_gl2gh")"
  log "PLAN ${repo} tags skip clash: $(join_csv <"${work}/t_clash")"
}

sync_repo_bidirectional() {
  local repo="$1"
  local orig_on_gh="${REPO_ON_GITHUB[$repo]:-0}"
  local orig_on_gl="${REPO_ON_GITLAB[$repo]:-0}"
  local is_private="${REPO_PRIVATE[$repo]:-false}"
  local gl_vis="${REPO_GL_VISIBILITY[$repo]:-private}"
  local gh_url gl_url dir
  local created_gh=0 created_gl=0
  local gh_refs gl_refs gl_code
  local work push_fail=0 name src_default=""
  local json

  gh_url=$(github_remote_url "$repo")
  gl_url=$(gitlab_remote_url "$repo")
  dir="${MIRROR_CACHE}/${repo}.git"

  log "=== ${repo} (bidirectional) ==="

  gl_code=$(gitlab_project_http_code "$repo")
  if [[ "$gl_code" == "000" ]] || gitlab_http_retryable "$gl_code"; then
    error "${repo}: could not reach GitLab API or project URL (HTTP ${gl_code})."
    return 1
  fi
  [[ "$gl_code" == "200" ]] && orig_on_gl=1

  gh_refs=""
  if [[ "$orig_on_gh" == "1" ]]; then
    gh_refs=$(ls_remote_refs_normalized "$gh_url" || true)
  fi
  gl_refs=""
  if [[ "$gl_code" == "200" ]]; then
    gl_refs=$(ls_remote_refs_normalized "$gl_url" || true)
  fi

  if [[ "$orig_on_gh" != "1" && "$gl_code" != "200" ]]; then
    error "${repo}: present in neither GitHub listing nor GitLab API; skipping."
    return 1
  fi

  if [[ "$orig_on_gh" != "1" ]]; then
    is_private=$(gitlab_visibility_to_github_private "$gl_vis")
    log "MISSING ${repo}: GitHub repository not found; creating (private=${is_private})"
    github_create_repo "$repo" "$is_private" || return 1
    created_gh=1
    json=$(gitlab_get_project_json "$repo" 2>/dev/null || true)
    src_default=$(printf '%s' "$json" | jq -r '.default_branch // empty')
  fi

  if [[ "$gl_code" != "200" ]]; then
    log "MISSING ${repo}: GitLab project not found (HTTP ${gl_code})"
    gitlab_create_project "$repo" "$is_private" || return 1
    created_gl=1
    gl_code=200
    github_api_request GET "${GITHUB_API}/repos/${GITHUB_USER}/${repo}"
    if [[ "${GITHUB_HTTP_CODE}" == "200" ]]; then
      src_default=$(printf '%s' "${GITHUB_LAST_BODY}" | jq -r '.default_branch // empty')
    fi
  fi

  if [[ "$orig_on_gh" == "1" && "$orig_on_gl" == "1" && "$created_gh" -eq 0 && "$created_gl" -eq 0 ]]; then
    gitlab_sync_visibility "$repo" "$is_private"
  fi

  if [[ -z "$gh_refs" && -z "$gl_refs" ]]; then
    log "OK ${repo}: both sides empty, no action"
    maybe_sync_github_issues "$repo" "$gl_code"
    return 0
  fi

  if [[ -n "$gh_refs" && "$gh_refs" == "$gl_refs" ]]; then
    log "OK ${repo}: identical to GitLab (ls-remote), no action"
    maybe_sync_github_issues "$repo" "$gl_code"
    return 0
  fi

  work=$(mktemp -d "${TMPDIR:-/tmp}/mirror-bidi.XXXXXX")
  : >"${work}/h_gh2gl" ; : >"${work}/h_gl2gh" ; : >"${work}/h_diverged" ; : >"${work}/h_fetch"
  : >"${work}/t_gh2gl" ; : >"${work}/t_gl2gh" ; : >"${work}/t_clash"
  parse_ls_remote_heads_tags "$gh_refs" "${work}/gh_heads" "${work}/gh_tags"
  parse_ls_remote_heads_tags "$gl_refs" "${work}/gl_heads" "${work}/gl_tags"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    classify_heads "$dir" "${work}/gh_heads" "${work}/gl_heads" 0 \
      "${work}/h_gh2gl" "${work}/h_gl2gh" "${work}/h_diverged" "${work}/h_fetch"
    classify_tags "${work}/gh_tags" "${work}/gl_tags" \
      "${work}/t_gh2gl" "${work}/t_gl2gh" "${work}/t_clash"
    log_bidirectional_plan "$repo" "$work"
    dry "git fetch both remotes into namespaced refs; push listed refspecs (no prune)"
    maybe_sync_github_issues "$repo" "$gl_code"
    rm -rf "$work"
    return 0
  fi

  log "DIFF ${repo}: ref lists differ; classifying via local bare cache"

  ensure_bare_cache "$dir" || {
    error "${repo}: failed to initialize bare cache."
    rm -rf "$work"
    return 1
  }
  ensure_git_remote "$dir" github "$gh_url"
  ensure_git_remote "$dir" gitlab "$gl_url"
  if ! fetch_bidirectional_refs "$dir"; then
    error "${repo}: git fetch from GitHub and/or GitLab failed."
    rm -rf "$work"
    return 1
  fi

  write_cache_refs "$dir" "refs/remotes/github/" "${work}/gh_heads"
  write_cache_refs "$dir" "refs/remotes/gitlab/" "${work}/gl_heads"
  write_cache_refs "$dir" "refs/sync/github/tags/" "${work}/gh_tags"
  write_cache_refs "$dir" "refs/sync/gitlab/tags/" "${work}/gl_tags"
  : >"${work}/h_gh2gl" ; : >"${work}/h_gl2gh" ; : >"${work}/h_diverged" ; : >"${work}/h_fetch"
  : >"${work}/t_gh2gl" ; : >"${work}/t_gl2gh" ; : >"${work}/t_clash"
  classify_heads "$dir" "${work}/gh_heads" "${work}/gl_heads" 1 \
    "${work}/h_gh2gl" "${work}/h_gl2gh" "${work}/h_diverged" "${work}/h_fetch"
  classify_tags "${work}/gh_tags" "${work}/gl_tags" \
    "${work}/t_gh2gl" "${work}/t_gl2gh" "${work}/t_clash"
  log_bidirectional_plan "$repo" "$work"

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    warn "${repo}: diverged branch '${name}'; skipping (neither side is a fast-forward)"
  done <"${work}/h_diverged"

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    warn "${repo}: tag clash '${name}' (different SHA); skipping"
  done <"${work}/t_clash"

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    log "PUSH ${repo}: GH→GL branch ${name}"
    if ! push_named_ref "$dir" gitlab "refs/remotes/github/${name}" "refs/heads/${name}"; then
      warn "${repo}: push GH→GL branch '${name}' failed (protected branch or rejected)."
      push_fail=$((push_fail + 1))
    fi
  done <"${work}/h_gh2gl"

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    log "PUSH ${repo}: GL→GH branch ${name}"
    if ! push_named_ref "$dir" github "refs/remotes/gitlab/${name}" "refs/heads/${name}"; then
      warn "${repo}: push GL→GH branch '${name}' failed (protected branch or rejected)."
      push_fail=$((push_fail + 1))
    fi
  done <"${work}/h_gl2gh"

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    log "PUSH ${repo}: GH→GL tag ${name}"
    if ! push_named_ref "$dir" gitlab "refs/sync/github/tags/${name}" "refs/tags/${name}"; then
      warn "${repo}: push GH→GL tag '${name}' failed."
      push_fail=$((push_fail + 1))
    fi
  done <"${work}/t_gh2gl"

  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    log "PUSH ${repo}: GL→GH tag ${name}"
    if ! push_named_ref "$dir" github "refs/sync/gitlab/tags/${name}" "refs/tags/${name}"; then
      warn "${repo}: push GL→GH tag '${name}' failed."
      push_fail=$((push_fail + 1))
    fi
  done <"${work}/t_gl2gh"

  if [[ "$created_gh" -eq 1 ]]; then
    github_set_default_branch "$repo" "$src_default"
  elif [[ "$created_gl" -eq 1 ]]; then
    gitlab_set_default_branch "$repo" "$src_default"
  fi

  rm -rf "$work"

  maybe_sync_github_issues "$repo" 200
  if [[ "$push_fail" -gt 0 ]]; then
    error "${repo}: ${push_fail} ref push(es) failed."
    return 1
  fi
  return 0
}

sync_repo() {
  local repo="$1"
  if [[ "$BIDIRECTIONAL" -eq 1 ]]; then
    sync_repo_bidirectional "$repo"
    return $?
  fi
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
  REPO_ON_GITHUB["$name"]=1
done <"$idx"
rm -f "$idx"

if [[ "$BIDIRECTIONAL" -eq 1 ]]; then
  glidx="${MIRROR_CACHE}/.gitlab-repo-index.tsv.tmp.$$"
  if ! fetch_gitlab_project_index >"$glidx"; then
    rm -f "$glidx"
    error "Failed to list GitLab projects (check GITLAB_TOKEN, namespace, and network)."
    exit 1
  fi
  while IFS=$'\t' read -r name vis; do
    [[ -z "${name:-}" ]] && continue
    REPO_ON_GITLAB["$name"]=1
    REPO_GL_VISIBILITY["$name"]="$vis"
    if [[ -z "${REPO_ON_GITHUB[$name]:-}" ]]; then
      REPO_NAMES+=("$name")
      REPO_PRIVATE["$name"]=$(gitlab_visibility_to_github_private "$vis")
    fi
  done <"$glidx"
  rm -f "$glidx"
fi

if [[ ${#REPO_NAMES[@]} -eq 0 ]]; then
  if [[ "$BIDIRECTIONAL" -eq 1 ]]; then
    log "No repositories returned (GitHub affiliation=owner union GitLab owned projects)."
  else
    log "No repositories returned (affiliation=owner)."
  fi
  exit 0
fi

if [[ "$BIDIRECTIONAL" -eq 1 ]]; then
  log "Processing ${#REPO_NAMES[@]} repo(s) (bidirectional; GitHub+GitLab union)."
else
  log "Processing ${#REPO_NAMES[@]} GitHub repo(s) (owner, including your forks)."
fi
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
