#!/usr/bin/env bash
# Mirror GitHub Gists -> GitLab Snippets (personal snippets).
#
# Env (required): GITHUB_USER, GITHUB_TOKEN, GITLAB_USER, GITLAB_TOKEN
# Optional: GITHUB_API, GITLAB_HOST (default https://gitlab.com),
#           GITLAB_API_RETRIES (default 3), GITLAB_API_RETRY_DELAY seconds (default 2)

set -euo pipefail

if [[ -z "${GITHUB_USER:-}" || -z "${GITHUB_TOKEN:-}" || -z "${GITLAB_USER:-}" || -z "${GITLAB_TOKEN:-}" ]]; then
  echo "Error: Missing required environment variables." >&2
  echo "Please ensure GITHUB_USER, GITHUB_TOKEN, GITLAB_USER, and GITLAB_TOKEN are set." >&2
  exit 1
fi

GITHUB_API="${GITHUB_API:-https://api.github.com}"
GITLAB_HOST="${GITLAB_HOST:-https://gitlab.com}"
GITLAB_HOST="${GITLAB_HOST%/}"
GITLAB_API="${GITLAB_HOST}/api/v4"
GITLAB_API_RETRIES="${GITLAB_API_RETRIES:-3}"
GITLAB_API_RETRY_DELAY="${GITLAB_API_RETRY_DELAY:-2}"

GIST_DESC_PREFIX="Synced from GitHub Gist "

log()  { printf '%s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }

gitlab_http_retryable() {
  case "$1" in
    000|429|502|503|504) return 0 ;;
    *) return 1 ;;
  esac
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

# Sets GITLAB_HTTP_CODE and GITLAB_LAST_BODY.
gitlab_api_request() {
  local method="$1" url="$2" body="${3:-}"
  local attempt delay max_retries code body_tmp curl_args=()
  max_retries="${GITLAB_API_RETRIES}"
  delay="${GITLAB_API_RETRY_DELAY}"
  body_tmp=$(mktemp)

  for attempt in $(seq 1 "$max_retries"); do
    curl_args=(-sS -o "$body_tmp" -w '%{http_code}' -X "$method"
      -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" -H "Content-Type: application/json")
    if [[ -n "$body" ]]; then
      code=$(curl "${curl_args[@]}" -d "$body" "$url" 2>/dev/null) || code="000"
    else
      code=$(curl "${curl_args[@]}" "$url" 2>/dev/null) || code="000"
    fi

    if gitlab_http_retryable "$code" && [[ "$attempt" -lt "$max_retries" ]]; then
      warn "GitLab ${method} ${url}: HTTP ${code}, retry ${attempt}/${max_retries} in ${delay}s"
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

github_gist_visibility() {
  [[ "$1" == "true" ]] && printf 'public' || printf 'private'
}

gist_gitlab_description() {
  printf '%s%s' "$GIST_DESC_PREFIX" "$1"
}

# GitLab PUT /snippets/:id requires files[].action (create|update|delete|move).
build_snippet_update_files() {
  local github_files_json="$1"
  local snippet_detail="$2"
  jq -n \
    --argjson gh "$github_files_json" \
    --argjson detail "$snippet_detail" \
    '
    ($detail.files // []) as $raw_gl |
    (if ($raw_gl | length) > 0 then $raw_gl
     elif ($detail.file_name // "") != "" then [{path: $detail.file_name}]
     else [] end) as $gl |
    ($gh | map(.file_path)) as $gh_paths |
    ($gl | map(.path)) as $gl_paths |
    (($gh | map(
      if (.file_path as $p | $gl_paths | index($p)) != null then
        {action: "update", file_path: .file_path, content: .content}
      else
        {action: "create", file_path: .file_path, content: .content}
      end
    )) + ($gl | map(select(.path as $p | ($gh_paths | index($p)) == null))
      | map({action: "delete", file_path: .path})))
    '
}

log "Fetching all (public and secret) Gists for authenticated user..."

GISTS=$(curl -sS -f -H "Authorization: token ${GITHUB_TOKEN}" \
  "${GITHUB_API}/gists?per_page=100") || {
  echo "Error: failed to list GitHub gists." >&2
  exit 1
}

if printf '%s' "$GISTS" | jq -e '.message' >/dev/null 2>&1; then
  echo "GitHub API Error: $(printf '%s' "$GISTS" | jq -r '.message')" >&2
  exit 1
fi

GIST_COUNT=$(printf '%s' "$GISTS" | jq 'length')
log "Found ${GIST_COUNT} Gist(s) on GitHub."

if [[ "$GIST_COUNT" -eq 0 ]]; then
  log "Nothing to mirror."
  exit 0
fi

log "Fetching existing GitLab snippets..."
gitlab_api_request GET "${GITLAB_API}/snippets"
if [[ "${GITLAB_HTTP_CODE}" != "200" ]]; then
  msg=$(gitlab_api_error_message "${GITLAB_LAST_BODY}")
  echo "Error: failed to list GitLab snippets (HTTP ${GITLAB_HTTP_CODE}): ${msg}" >&2
  exit 1
fi
EXISTING_SNIPPETS="${GITLAB_LAST_BODY}"

failures=0

while IFS= read -r gist; do
  [[ -z "$gist" ]] && continue

  GIST_ID=$(printf '%s' "$gist" | jq -r '.id')
  DESCRIPTION=$(printf '%s' "$gist" | jq -r '.description // ""')
  IS_PUBLIC=$(printf '%s' "$gist" | jq -r '.public')
  VISIBILITY=$(github_gist_visibility "$IS_PUBLIC")
  GIST_DESC=$(gist_gitlab_description "$GIST_ID")

  FIRST_FILE=$(printf '%s' "$gist" | jq -r '.files | keys[0]')
  TITLE="$DESCRIPTION"
  if [[ -z "$TITLE" || "$TITLE" == "null" ]]; then
    TITLE="$FIRST_FILE"
  fi

  log "--------------------------------------------------"
  log "Processing Gist ID: ${GIST_ID} (${TITLE})"

  FILES_JSON=$(printf '%s' "$gist" | jq -c '[.files[] | {file_path: .filename, content: .content}]')

  if printf '%s' "$FILES_JSON" | jq -e '.[] | select(.content == null)' >/dev/null 2>&1; then
    log "Fetching raw content for files..."
    FILES_JSON="[]"
    while IFS= read -r file_info; do
      [[ -z "$file_info" ]] && continue
      FILENAME=$(printf '%s' "$file_info" | jq -r '.filename')
      RAW_URL=$(printf '%s' "$file_info" | jq -r '.raw_url')
      CONTENT=$(curl -sS -f -H "Authorization: token ${GITHUB_TOKEN}" "$RAW_URL") || {
        warn "${GIST_ID}: failed to fetch raw content for ${FILENAME}; skipping gist."
        FILES_JSON=""
        break
      }
      FILES_JSON=$(printf '%s' "$FILES_JSON" | jq --arg name "$FILENAME" --arg ctx "$CONTENT" \
        '. += [{file_path: $name, content: $ctx}]')
    done < <(printf '%s' "$gist" | jq -c '.files[]')
    [[ -z "$FILES_JSON" ]] && { failures=$((failures + 1)); continue; }
  fi

  SNIPPET_JSON=$(printf '%s' "$EXISTING_SNIPPETS" | jq -c --arg desc "$GIST_DESC" --arg title "$TITLE" '
    ([.[] | select(.description == $desc)][0] // [.[] | select(.title == $title)][0] // empty)')
  SNIPPET_ID=$(printf '%s' "$SNIPPET_JSON" | jq -r '.id // empty')
  CURRENT_VISIBILITY=$(printf '%s' "$SNIPPET_JSON" | jq -r '.visibility // empty')

  if [[ -n "$SNIPPET_ID" ]]; then
    if [[ -n "$CURRENT_VISIBILITY" && "$CURRENT_VISIBILITY" != "$VISIBILITY" ]]; then
      log "VISIBILITY ${GIST_ID}: GitLab=${CURRENT_VISIBILITY} GitHub=${VISIBILITY}; updating GitLab snippet"
    fi
    log "Found existing GitLab Snippet ID: ${SNIPPET_ID}. Updating..."

    gitlab_api_request GET "${GITLAB_API}/snippets/${SNIPPET_ID}"
    if [[ "${GITLAB_HTTP_CODE}" != "200" ]]; then
      msg=$(gitlab_api_error_message "${GITLAB_LAST_BODY}")
      warn "${GIST_ID}: failed to read GitLab snippet ${SNIPPET_ID} (HTTP ${GITLAB_HTTP_CODE}): ${msg}"
      failures=$((failures + 1))
      continue
    fi

    UPDATE_FILES=$(build_snippet_update_files "$FILES_JSON" "${GITLAB_LAST_BODY}")
    PAYLOAD=$(jq -n \
      --arg title "$TITLE" \
      --arg desc "$GIST_DESC" \
      --arg vis "$VISIBILITY" \
      --argjson files "$UPDATE_FILES" \
      '{title: $title, description: $desc, visibility: $vis, files: $files}')

    gitlab_api_request PUT "${GITLAB_API}/snippets/${SNIPPET_ID}" "$PAYLOAD"
    if [[ "${GITLAB_HTTP_CODE}" != "200" ]]; then
      msg=$(gitlab_api_error_message "${GITLAB_LAST_BODY}")
      warn "${GIST_ID}: failed to update GitLab snippet ${SNIPPET_ID} (HTTP ${GITLAB_HTTP_CODE}): ${msg}"
      failures=$((failures + 1))
      continue
    fi
    log "Successfully updated snippet ${SNIPPET_ID}."
  else
    PAYLOAD=$(jq -n \
      --arg title "$TITLE" \
      --arg desc "$GIST_DESC" \
      --arg vis "$VISIBILITY" \
      --argjson files "$FILES_JSON" \
      '{title: $title, description: $desc, visibility: $vis, files: $files}')

    log "No existing snippet found. Creating new GitLab snippet (visibility=${VISIBILITY})..."
    gitlab_api_request POST "${GITLAB_API}/snippets" "$PAYLOAD"
    if [[ "${GITLAB_HTTP_CODE}" != "201" ]]; then
      msg=$(gitlab_api_error_message "${GITLAB_LAST_BODY}")
      warn "${GIST_ID}: failed to create GitLab snippet (HTTP ${GITLAB_HTTP_CODE}): ${msg}"
      failures=$((failures + 1))
      continue
    fi
    NEW_ID=$(printf '%s' "${GITLAB_LAST_BODY}" | jq -r '.id // empty')
    log "Successfully created Snippet ID: ${NEW_ID}"
  fi
done < <(printf '%s' "$GISTS" | jq -c '.[]')

log "--------------------------------------------------"
if [[ "$failures" -gt 0 ]]; then
  warn "Mirroring finished with ${failures} failure(s) out of ${GIST_COUNT} gist(s)."
  exit 1
fi
log "Mirroring complete!"
